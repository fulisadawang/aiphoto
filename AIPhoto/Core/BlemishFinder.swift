import CoreGraphics
import CoreImage
import Foundation

/// 自动找斑：在脸部皮肤上找比周围暗或比周围红的小点（蚊子包、抓痕、痘），只列出来，不自动修。
/// 规则分不出痣和斑，所以找到的全部画圈，由摄影师逐个决定（第 19.1 节）
enum BlemishFinder {
    struct Spot: Identifiable, Equatable {
        let id = UUID()
        /// 归一化中心（原点左上），相对于方向校正后的整张照片
        let center: CGPoint
        /// 半径，以画面宽度为单位（与画笔一致）
        let radius: CGFloat
        /// 与周围的差异，越大越明显，用来排序和限制数量
        let strength: Float
    }

    /// 在脸宽这么多像素的裁图上找
    static let workWidth = 512
    /// 脸宽小于这么多原图像素不找（合影小脸），只能手动点修
    static let minFacePixels = 150.0
    /// 每张脸最多列出的个数
    static let maxSpotsPerFace = 30
    /// 比周围暗 / 比周围红的门槛（0～1）
    static let darkThreshold: Float = 0.06
    static let redThreshold: Float = 0.05
    /// 斑点四周一圈里像皮肤的像素至少占这么多，才算长在皮肤上（排除刘海、睫毛、唇边、发际线）
    static let minSkinAround = 0.85

    static func find(in photo: Photo, folder: URL) throws -> [Spot] {
        guard let faces = photo.analysis?.faces.filter({ $0.shape != nil }), !faces.isEmpty,
              let source = PhotoRenderer.fullResolution(of: photo)
        else { return [] }
        // 在已有修补之上找，修过的不再列出
        let base = try PhotoRenderer.composite(source, patches: photo.cleanups ?? [], folder: folder)
        let extent = base.extent
        var spots: [Spot] = []
        for face in faces {
            guard let shape = face.shape, face.box.width * extent.width >= minFacePixels else { continue }
            spots += find(face: face, shape: shape, base: base)
        }
        return spots
    }

    private static func find(face: FaceInfo, shape: FaceShape, base: CIImage) -> [Spot] {
        let extent = base.extent
        // 脸框外扩一些，额头和下巴都在里面；归一化坐标（原点左上）
        let region = face.box.insetBy(dx: -face.box.width * 0.15, dy: -face.box.height * 0.25)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let crop = CGRect(
            x: extent.minX + region.minX * extent.width, y: extent.minY + (1 - region.maxY) * extent.height,
            width: region.width * extent.width, height: region.height * extent.height
        ).integral
        let scale = CGFloat(workWidth) / crop.width
        let width = workWidth, height = max(1, Int((crop.height * scale).rounded()))
        let scaled = base.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY).concatenating(CGAffineTransform(scaleX: scale, y: scale)))
        // 图和蒙版都画进 CGContext 的内存，第 0 行在顶部
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        guard let cgImage = PhotoRenderer.context.createCGImage(
                  scaled, from: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: PhotoRenderer.sRGB
              ),
              rgba.withUnsafeMutableBytes({ raw -> Bool in
                  guard let context = CGContext(
                      data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: PhotoRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
                  context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
                  return true
              }),
              var skin = skinMask(shape: shape, region: region, width: width, height: height, forehead: false),
              let withForehead = skinMask(shape: shape, region: region, width: width, height: height, forehead: true)
        else { return [] }

        let count = width * height
        var luma = [Float](repeating: 0, count: count), red = luma, chromaR = luma, chromaG = luma
        for i in 0..<count {
            let r = Float(rgba[i * 4]) / 255, g = Float(rgba[i * 4 + 1]) / 255, b = Float(rgba[i * 4 + 2]) / 255
            luma[i] = 0.299 * r + 0.587 * g + 0.114 * b
            red[i] = r - g
            let sum = max(r + g + b, 0.001)
            chromaR[i] = r / sum
            chromaG[i] = g / sum
        }
        // 这张脸的肤色（皮肤范围内的中位数）：刘海、睫毛这些虽在脸轮廓里但颜色差得远。
        // 实拍发现：只按脸轮廓找，刘海和眼角、嘴角会被大量误报
        func median(_ values: [Float]) -> Float {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        let skinIndices = (0..<count).filter { skin[$0] }
        let toneR = median(skinIndices.map { chromaR[$0] }), toneG = median(skinIndices.map { chromaG[$0] })
        let toneLuma = median(skinIndices.map { luma[$0] })
        func looksLikeSkin(_ i: Int) -> Bool {
            abs(chromaR[i] - toneR) < 0.045 && abs(chromaG[i] - toneG) < 0.03 && luma[i] > toneLuma * 0.6
        }
        // 额头常被刘海盖住（实拍：逆光的刘海颜色接近肤色，会被当成斑）：额头大半像皮肤才一起找
        let forehead = (0..<count).filter { withForehead[$0] && !skin[$0] }
        if !forehead.isEmpty, Double(forehead.filter(looksLikeSkin).count) / Double(forehead.count) >= 0.7 {
            skin = withForehead
        }
        let skinLike = (0..<count).map { skin[$0] && looksLikeSkin($0) }
        // 周围的样子：只在皮肤上做大范围平均（约脸宽 4%），斑点本身影响很小
        let radius = max(4, width / 25)
        let lumaAround = maskedBlur(luma, mask: skin, width: width, height: height, radius: radius)
        let redAround = maskedBlur(red, mask: skin, width: width, height: height, radius: radius)
        var score = [Float](repeating: 0, count: count)
        for i in 0..<count where skin[i] {
            let dark = lumaAround[i] - luma[i] - darkThreshold
            let reddish = red[i] - redAround[i] - redThreshold
            score[i] = max(dark / darkThreshold, reddish / redThreshold)
        }

        // 连通的候选像素合成一个点，按大小和形状筛
        var visited = [Bool](repeating: false, count: count)
        var spots: [Spot] = []
        let minDiameter = Double(width) * 0.008, maxDiameter = Double(width) * 0.06
        for start in 0..<count where score[start] > 0 && !visited[start] {
            var stack = [start], pixels: [Int] = []
            visited[start] = true
            while let p = stack.popLast() {
                pixels.append(p)
                let x = p % width, y = p / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let q = ny * width + nx
                    if !visited[q] && score[q] > 0 { visited[q] = true; stack.append(q) }
                }
            }
            let xs = pixels.map { $0 % width }, ys = pixels.map { $0 / width }
            let w = Double(xs.max()! - xs.min()! + 1), h = Double(ys.max()! - ys.min()! + 1)
            let diameter = max(w, h)
            // 太小的是噪点，太大的是阴影；细长的是头发丝、睫毛、皱纹
            guard diameter >= minDiameter, diameter <= maxDiameter, max(w, h) / min(w, h) < 3, pixels.count >= 6 else { continue }
            // 四周一圈（外扩一个直径）要几乎都是皮肤
            let reach = Int(diameter.rounded(.up))
            let members = Set(pixels)
            var around = 0, skinAround = 0
            for y in max(0, ys.min()! - reach)...min(height - 1, ys.max()! + reach) {
                for x in max(0, xs.min()! - reach)...min(width - 1, xs.max()! + reach) where !members.contains(y * width + x) {
                    around += 1
                    if skinLike[y * width + x] { skinAround += 1 }
                }
            }
            guard around > 0, Double(skinAround) / Double(around) >= minSkinAround else { continue }
            let cx = Double(xs.reduce(0, +)) / Double(pixels.count) + 0.5
            let cy = Double(ys.reduce(0, +)) / Double(pixels.count) + 0.5
            let strength = pixels.map { score[$0] }.max()!
            // 裁图坐标（第 0 行在顶部）→ 整张照片的归一化坐标（原点左上）
            let center = CGPoint(
                x: region.minX + cx / Double(width) * region.width,
                y: region.minY + cy / Double(height) * region.height
            )
            // 斑点边缘是渐淡的，按检测到的大小修会留一圈淡印（模拟蚊子包实测），修的圈放大到 1.8 倍
            let spotRadius = diameter / 2 * 1.8 / Double(width) * region.width
            spots.append(Spot(center: center, radius: spotRadius, strength: strength))
        }
        return Array(spots.sorted { $0.strength > $1.strength }.prefix(maxSpotsPerFace))
    }

    /// 皮肤范围：脸轮廓（forehead 时加上额头），挖掉眼、眉、嘴和鼻孔（按五官位置推算，旧记录不用补测关键点）。第 0 行在顶部
    private static func skinMask(shape: FaceShape, region: CGRect, width: Int, height: Int, forehead: Bool) -> [Bool]? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - region.minX) / region.width * CGFloat(width), y: (region.maxY - p.y) / region.height * CGFloat(height))
        }
        func polygon(_ points: [CGPoint]) -> CGPath {
            let path = CGMutablePath()
            path.addLines(between: points.map(point))
            path.closeSubpath()
            return path
        }
        let eyeDistance = hypot(shape.rightPupil.x - shape.leftPupil.x, shape.rightPupil.y - shape.leftPupil.y)
        let browTop = (shape.leftEyebrow + shape.rightEyebrow).map(\.y).min() ?? shape.leftPupil.y
        // 脸轮廓不含额头：在眉毛上方补一块，高约 0.5 个眼距
        var outline = shape.faceContour
        if forehead, let first = shape.faceContour.first, let last = shape.faceContour.last {
            let top = browTop - eyeDistance * 0.5
            outline += [CGPoint(x: last.x, y: top), CGPoint(x: first.x, y: top)]
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(polygon(outline))
        context.fillPath()

        // 五官挖掉时放宽一圈，睫毛、眉毛边、唇线、眼角和嘴角的褶子不算斑
        let pad = eyeDistance * 0.15 / region.width * CGFloat(width)
        context.setFillColor(gray: 0, alpha: 1)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(pad * 2)
        context.setLineJoin(.round)
        for feature in [shape.leftEye, shape.rightEye, shape.leftEyebrow, shape.rightEyebrow, shape.outerLips] where feature.count > 2 {
            context.addPath(polygon(feature))
            context.drawPath(using: .fillStroke)
        }
        // 鼻孔：两瞳孔中点下方、上唇之上，宽约 0.7 个眼距
        let mid = CGPoint(x: (shape.leftPupil.x + shape.rightPupil.x) / 2, y: (shape.leftPupil.y + shape.rightPupil.y) / 2)
        let lipTop = shape.outerLips.map(\.y).min() ?? mid.y + eyeDistance
        let nostrilTop = mid.y + (lipTop - mid.y) * 0.55
        context.addPath(polygon([
            CGPoint(x: mid.x - eyeDistance * 0.35, y: nostrilTop), CGPoint(x: mid.x + eyeDistance * 0.35, y: nostrilTop),
            CGPoint(x: mid.x + eyeDistance * 0.35, y: lipTop), CGPoint(x: mid.x - eyeDistance * 0.35, y: lipTop),
        ]))
        context.fillPath()

        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return (0..<(width * height)).map { data[$0] > 127 }
    }

    /// 只对皮肤像素做方框平均（积分图），周围不是皮肤的地方不参与
    private static func maskedBlur(_ values: [Float], mask: [Bool], width: Int, height: Int, radius: Int) -> [Float] {
        let stride = width + 1
        var sum = [Double](repeating: 0, count: stride * (height + 1)), weight = sum
        for y in 0..<height {
            var rowSum = 0.0, rowWeight = 0.0
            for x in 0..<width {
                if mask[y * width + x] { rowSum += Double(values[y * width + x]); rowWeight += 1 }
                sum[(y + 1) * stride + x + 1] = sum[y * stride + x + 1] + rowSum
                weight[(y + 1) * stride + x + 1] = weight[y * stride + x + 1] + rowWeight
            }
        }
        var result = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let x0 = max(0, x - radius), y0 = max(0, y - radius), x1 = min(width, x + radius + 1), y1 = min(height, y + radius + 1)
                let s = sum[y1 * stride + x1] - sum[y0 * stride + x1] - sum[y1 * stride + x0] + sum[y0 * stride + x0]
                let w = weight[y1 * stride + x1] - weight[y0 * stride + x1] - weight[y1 * stride + x0] + weight[y0 * stride + x0]
                result[y * width + x] = w > 0 ? Float(s / w) : values[y * width + x]
            }
        }
        return result
    }
}
