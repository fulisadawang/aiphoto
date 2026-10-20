import CoreGraphics
import CoreImage
import Foundation
import Vision

/// 多图合成：从同一场拍摄的另一张照片里抠出主体（人、动物、物品），放到当前照片里，生成一块修补贴回。
/// 结果和去杂物一样是 CleanupPatch，预览、导出、撤销、修复前后对比都沿用同一套流程
enum Compositor {
    enum CompositeError: LocalizedError {
        case unreadable
        case noSubject
        case render
        var errorDescription: String? {
            switch self {
            case .unreadable: "无法读取照片"
            case .noSubject: "这里没有识别到可以抠出的主体，换个位置点，或用画笔涂出要拿的部分"
            case .render: "生成合成结果失败"
            }
        }
    }

    // MARK: - 抠主体

    /// 一张来源照片的分割结果：人物逐个分开，其余主体（动物、物品）按显著性分开
    struct Segmentation: @unchecked Sendable {
        let image: CGImage
        let handler: VNImageRequestHandler
        let people: VNInstanceMaskObservation?
        let foreground: VNInstanceMaskObservation?
    }

    /// image：方向已转正的来源照片（建议长边 2048 左右，兼顾边缘精度和速度）
    static func segment(_ image: CGImage) throws -> Segmentation {
        let handler = VNImageRequestHandler(cgImage: image)
        let people = VNGeneratePersonInstanceMaskRequest()
        let foreground = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([people, foreground])
        return Segmentation(image: image, handler: handler, people: people.results?.first, foreground: foreground.results?.first)
    }

    struct Selection {
        /// 与分割用的图同尺寸的灰度蒙版，白色为选中
        let mask: CGImage
        let isPerson: Bool
    }

    /// 点一下选中一个主体：点到人选这个人，否则选点到的显著主体。peopleOnly 时只找人
    static func select(at point: CGPoint, in segmentation: Segmentation, peopleOnly: Bool = false) throws -> Selection {
        let candidates = [(segmentation.people, true)] + (peopleOnly ? [] : [(segmentation.foreground, false)])
        for case let (observation?, isPerson) in candidates {
            guard let label = instanceLabel(at: point, in: observation.instanceMask), label > 0,
                  observation.allInstances.contains(Int(label))
            else { continue }
            let buffer = try observation.generateScaledMaskForImage(forInstances: [Int(label)], from: segmentation.handler)
            guard let mask = grayImage(from: buffer) else { throw CompositeError.render }
            return Selection(mask: mask, isPerson: isPerson)
        }
        throw CompositeError.noSubject
    }

    /// instanceMask 每个像素是实例编号（0 为背景），原点左上
    private static func instanceLabel(at point: CGPoint, in buffer: CVPixelBuffer) -> UInt8? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))
        return base.load(fromByteOffset: y * CVPixelBufferGetBytesPerRow(buffer) + x, as: UInt8.self)
    }

    private static func grayImage(from buffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: buffer)
        return PhotoRenderer.context.createCGImage(image, from: image.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// 用画笔修正蒙版：add 为补选，否则为擦除。笔触坐标与 BrushStroke 一致（归一化，半径以宽度为单位）
    static func refine(_ mask: CGImage, strokes: [BrushStroke], add: Bool) -> CGImage? {
        let width = mask.width, height = mask.height
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext 原点在左下，笔触坐标原点在左上
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setStrokeColor(gray: add ? 1 : 0, alpha: 1)
        context.setFillColor(gray: add ? 1 : 0, alpha: 1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes {
            let lineWidth = stroke.radius * CGFloat(width) * 2
            let points = stroke.points.map { CGPoint(x: $0.x * CGFloat(width), y: $0.y * CGFloat(height)) }
            if points.count == 1 {
                context.fillEllipse(in: CGRect(x: points[0].x - lineWidth / 2, y: points[0].y - lineWidth / 2, width: lineWidth, height: lineWidth))
            } else {
                context.setLineWidth(lineWidth)
                context.addLines(between: points)
                context.strokePath()
            }
        }
        return context.makeImage()
    }

    /// 蒙版里选中区域的包围框（归一化，原点左上）；没有选中返回 nil
    static func boundingBox(of mask: CGImage) -> CGRect? {
        let width = mask.width, height = mask.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where bytes[row + x] > 127 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // 位图第 0 行是图像顶部
        return CGRect(
            x: CGFloat(minX) / CGFloat(width), y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width), height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
    }

    // MARK: - 连拍对齐

    /// 把来源照片上的一点映射到当前照片的对应位置（归一化，原点左上）。配准失败返回 nil，由界面改为手动放置。
    /// focus 为来源照片里主体所在区域：先整体配准，再在主体周围局部配准一次。
    /// 只做整体配准时，满屏的远处树枝主导结果，拍摄者移动造成的视差会让近处的房子、窗框对不齐（实拍差值图整座房子边缘都错开）
    static func alignment(source: CGImage, target: CGImage, focus: CGRect? = nil) -> ((CGPoint) -> CGPoint)? {
        guard let global = homography(from: source, to: target) else { return nil }
        let sw = CGFloat(source.width), sh = CGFloat(source.height), tw = CGFloat(target.width), th = CGFloat(target.height)
        func globalMap(_ point: CGPoint) -> CGPoint {
            let p = apply(global, x: point.x * sw, y: (1 - point.y) * sh)
            return CGPoint(x: p.x / tw, y: 1 - p.y / th)
        }
        // 位移过大说明不是同一机位，配准结果不可信
        let center = globalMap(CGPoint(x: 0.5, y: 0.5))
        guard abs(center.x - 0.5) < 0.25, abs(center.y - 0.5) < 0.25 else { return nil }
        guard let focus else { return globalMap }

        // 局部：主体四周各扩 60% 的区域，以及它按整体配准落在当前照片里的区域
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let sourceRegion = focus.insetBy(dx: -focus.width * 0.6, dy: -focus.height * 0.6).intersection(unit)
        let mapped = [CGPoint(x: sourceRegion.minX, y: sourceRegion.minY), CGPoint(x: sourceRegion.maxX, y: sourceRegion.maxY)].map(globalMap)
        let targetRegion = CGRect(x: mapped[0].x, y: mapped[0].y, width: mapped[1].x - mapped[0].x, height: mapped[1].y - mapped[0].y).intersection(unit)
        let sourcePixels = CGRect(x: sourceRegion.minX * sw, y: sourceRegion.minY * sh, width: sourceRegion.width * sw, height: sourceRegion.height * sh).integral
        let targetPixels = CGRect(x: targetRegion.minX * tw, y: targetRegion.minY * th, width: targetRegion.width * tw, height: targetRegion.height * th).integral
        guard sourcePixels.width >= 128, sourcePixels.height >= 128, targetPixels.width >= 128, targetPixels.height >= 128,
              let sourceCrop = source.cropping(to: sourcePixels), let targetCrop = target.cropping(to: targetPixels),
              let local = homography(from: sourceCrop, to: targetCrop)
        else { return globalMap }
        func localMap(_ point: CGPoint) -> CGPoint {
            // 来源归一化 → 来源局部像素（原点左下）→ 当前局部像素 → 当前归一化
            let x = point.x * sw - sourcePixels.minX, y = sourcePixels.maxY - point.y * sh
            let p = apply(local, x: x, y: y)
            return CGPoint(x: (targetPixels.minX + p.x) / tw, y: (targetPixels.maxY - p.y) / th)
        }
        // 局部结果和整体结果差太多（局部特征太少时会算飞）就不用
        let check = CGPoint(x: focus.midX, y: focus.midY)
        let a = localMap(check), b = globalMap(check)
        guard abs(a.x - b.x) < 0.05, abs(a.y - b.y) < 0.05 else { return globalMap }
        return localMap
    }

    /// Vision 配准：返回把 source 像素坐标（原点左下）映射到 target 像素坐标的矩阵
    private static func homography(from source: CGImage, to target: CGImage) -> simd_float3x3? {
        let request = VNHomographicImageRegistrationRequest(targetedCGImage: source)
        guard (try? VNImageRequestHandler(cgImage: target).perform([request])) != nil,
              let observation = request.results?.first as? VNImageHomographicAlignmentObservation
        else { return nil }
        return observation.warpTransform
    }

    private static func apply(_ matrix: simd_float3x3, x: CGFloat, y: CGFloat) -> CGPoint {
        let v = matrix * SIMD3<Float>(Float(x), Float(y), 1)
        guard v.z != 0 else { return CGPoint(x: x, y: y) }
        return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
    }

    /// 连拍换人：只贴新的人会露出原来那个人（姿势不同时出现两顶帽子的重影）。
    /// 把当前照片里对应那个人的范围（换算到来源照片坐标）也并进蒙版，再外扩一圈：
    /// 同一机位下来源照片这一圈是干净的背景，正好盖住原来的人。
    /// targetMask 与 sourceMask 同尺寸；offset 为当前照片相对来源照片的位移（归一化，当前 = 来源 + offset）
    /// 合并后的范围超过原主体 3 倍时返回 nil（多半是在当前照片里选错了对象）
    static func coverMask(sourceMask: CGImage, targetMask: CGImage, offset: CGPoint) -> CGImage? {
        let width = CGFloat(sourceMask.width), height = CGFloat(sourceMask.height)
        let source = CIImage(cgImage: sourceMask)
        let target = CIImage(cgImage: targetMask)
            .transformed(by: CGAffineTransform(scaleX: width / CGFloat(targetMask.width), y: height / CGFloat(targetMask.height)))
            // CI 原点在左下：归一化 y 向下为正，换成 CI 要取反
            .transformed(by: CGAffineTransform(translationX: -offset.x * width, y: offset.y * height))
        let union = target.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: source])
        let dilated = union.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: max(2, width * 0.006)])
            .cropped(to: source.extent)
        guard let merged = PhotoRenderer.context.createCGImage(dilated, from: source.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()),
              let before = boundingBox(of: sourceMask), let after = boundingBox(of: merged),
              after.width * after.height <= before.width * before.height * 3
        else { return nil }
        return merged
    }

    /// 当前照片里认不出对应的人（被窗框挡住、侧身）时的兜底：把来源主体向外扩一圈。
    /// 同一机位的连拍背景对齐，多带的这一圈背景看不出接缝，同时能盖住姿势略有不同的原来那个人
    static func expandedMask(_ mask: CGImage, fraction: CGFloat = 0.15) -> CGImage? {
        guard let box = boundingBox(of: mask) else { return nil }
        let radius = max(box.width * CGFloat(mask.width), box.height * CGFloat(mask.height)) * fraction / 2
        let image = CIImage(cgImage: mask)
        let dilated = image.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius]).cropped(to: image.extent)
        return PhotoRenderer.context.createCGImage(dilated, from: image.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    // MARK: - 合成

    /// 放置参数：主体在当前照片里的位置（归一化包围框，原点左上）和是否水平翻转
    struct Placement {
        var rect: CGRect
        var flipped = false
        /// 连拍对齐时的完整映射（来源归一化坐标 → 当前照片归一化坐标，含缩放、旋转、透视）。
        /// 有它时按它摆放，rect 只用于界面显示；手动拖动后清空
        var warp: ((CGPoint) -> CGPoint)?
    }

    /// 来源包围框在当前照片里默认的大小：保持主体的像素尺寸不变（同一机位时远近一致）
    static func defaultRect(sourceBox: CGRect, sourceSize: CGSize, targetSize: CGSize, center: CGPoint) -> CGRect {
        let width = sourceBox.width * sourceSize.width / targetSize.width
        let height = sourceBox.height * sourceSize.height / targetSize.height
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    /// 在全尺寸上生成合成修补块。source、target 都是方向已转正、已叠加各自去杂物结果的全尺寸图；
    /// mask 是来源照片的选中蒙版（任意分辨率，按比例缩放）
    static func bake(
        source: CIImage, mask: CGImage, sourceBox: CGRect, target: CIImage, placement: Placement, folder: URL
    ) throws -> CleanupPatch {
        let sourceSize = source.extent.size, targetSize = target.extent.size
        // 主体四周多带一圈，羽化边缘有过渡空间
        let pad = 0.04
        let box = sourceBox.insetBy(dx: -sourceBox.width * pad, dy: -sourceBox.height * pad)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let scale = placement.rect.width * targetSize.width / (sourceBox.width * sourceSize.width)
        var placed = CGRect(
            x: placement.rect.minX - (sourceBox.minX - box.minX) * sourceSize.width * scale / targetSize.width,
            y: placement.rect.minY - (sourceBox.minY - box.minY) * sourceSize.height * scale / targetSize.height,
            width: box.width * sourceSize.width * scale / targetSize.width,
            height: box.height * sourceSize.height * scale / targetSize.height
        )
        // 连拍对齐：来源局部四个角映射到当前照片，放置范围取映射后的包围框
        let warpedCorners = placement.warp.map { warp in
            [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)].map(warp)
        }
        if let corners = warpedCorners {
            let xs = corners.map(\.x), ys = corners.map(\.y)
            placed = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        let targetBounds = CGRect(origin: .zero, size: targetSize)
        let placedPixels = pixelRect(placed, in: targetSize).intersection(targetBounds).integral
        guard placedPixels.width >= 4, placedPixels.height >= 4 else { throw CompositeError.render }

        // 来源局部（CI 坐标原点左下）
        let sourceCrop = ciRect(pixelRect(box, in: sourceSize), height: sourceSize.height)
        let maskImage = CIImage(cgImage: mask)
            .transformed(by: CGAffineTransform(scaleX: sourceSize.width / CGFloat(mask.width), y: sourceSize.height / CGFloat(mask.height)))
        let feather = max(1.0, 1.2 * Double(sourceSize.width) / 2048)
        let softMask = maskImage.clampedToExtent().applyingGaussianBlur(sigma: feather).cropped(to: sourceCrop)
        var subject = source.cropped(to: sourceCrop)

        // 颜色匹配：比较两边主体周围一圈的平均色。同一机位的连拍几乎为 1，不同照片时修正明暗冷暖
        if let gain = ringGain(source: source, sourceBox: box, target: target, targetBox: placed) {
            subject = subject.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain.x, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: gain.y, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: gain.z, w: 0),
            ])
        }
        let cut = subject.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: softMask,
        ])

        // 来源局部 → 当前照片里的放置位置
        let moved: CIImage
        if let corners = warpedCorners {
            // 按配准结果做透视变换，窗框等背景细节才能和当前照片严丝合缝
            func ci(_ p: CGPoint) -> CIVector { CIVector(x: p.x * targetSize.width, y: (1 - p.y) * targetSize.height) }
            moved = cut.transformed(by: CGAffineTransform(translationX: -sourceCrop.minX, y: -sourceCrop.minY))
                .applyingFilter("CIPerspectiveTransform", parameters: [
                    "inputTopLeft": ci(corners[0]), "inputTopRight": ci(corners[1]),
                    "inputBottomRight": ci(corners[2]), "inputBottomLeft": ci(corners[3]),
                ])
        } else {
            let destination = ciRect(pixelRect(placed, in: targetSize), height: targetSize.height)
            var transform = CGAffineTransform(translationX: -sourceCrop.minX, y: -sourceCrop.minY)
            if placement.flipped {
                transform = transform.concatenating(CGAffineTransform(scaleX: -1, y: 1)).concatenating(CGAffineTransform(translationX: sourceCrop.width, y: 0))
            }
            transform = transform
                .concatenating(CGAffineTransform(scaleX: destination.width / sourceCrop.width, y: destination.height / sourceCrop.height))
                .concatenating(CGAffineTransform(translationX: destination.minX, y: destination.minY))
            moved = cut.transformed(by: transform)
        }
        let output = ciRect(placedPixels, height: targetSize.height)
        let patchImage = moved
            .cropped(to: output)
            .transformed(by: CGAffineTransform(translationX: -output.minX, y: -output.minY))

        let patch = CleanupPatch(id: UUID(), rect: CGRect(
            x: placedPixels.minX / targetSize.width, y: placedPixels.minY / targetSize.height,
            width: placedPixels.width / targetSize.width, height: placedPixels.height / targetSize.height
        ))
        try FileManager.default.createDirectory(at: CleanupEngine.patchDirectory(folder: folder), withIntermediateDirectories: true)
        try PhotoRenderer.context.writePNGRepresentation(
            of: patchImage, to: CleanupEngine.patchURL(patch.id, folder: folder), format: .RGBA8, colorSpace: PhotoRenderer.sRGB
        )
        return patch
    }

    /// 归一化（原点左上）→ 像素（原点左上）
    private static func pixelRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }

    /// 像素（原点左上）→ CI 坐标（原点左下）
    private static func ciRect(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// 两边包围框外扩 30% 的一圈平均色之比，限制在 ±20% 以内
    private static func ringGain(source: CIImage, sourceBox: CGRect, target: CIImage, targetBox: CGRect) -> CIVector? {
        func ringAverage(_ image: CIImage, _ box: CGRect) -> SIMD3<Float>? {
            let size = image.extent.size
            let outer = box.insetBy(dx: -box.width * 0.3, dy: -box.height * 0.3).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !outer.isNull else { return nil }
            let outerCI = ciRect(pixelRect(outer, in: size), height: size.height)
            let innerCI = ciRect(pixelRect(box, in: size), height: size.height)
            func average(_ rect: CGRect) -> SIMD4<Float>? {
                guard rect.width >= 1, rect.height >= 1 else { return nil }
                let avg = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)])
                var pixel = [Float](repeating: 0, count: 4)
                PhotoRenderer.context.render(
                    avg, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
                )
                return SIMD4(pixel[0], pixel[1], pixel[2], Float(rect.width * rect.height))
            }
            // 外框平均减去内框（主体本身）的贡献，得到一圈的平均色
            guard let o = average(outerCI), let i = average(innerCI.intersection(outerCI)) else { return nil }
            let area = o.w - i.w
            guard area > 0 else { return nil }
            return (SIMD3(o.x, o.y, o.z) * o.w - SIMD3(i.x, i.y, i.z) * i.w) / area
        }
        guard let s = ringAverage(source, sourceBox), let t = ringAverage(target, targetBox), s.min() > 0.001 else { return nil }
        let gain = simd_clamp(t / s, SIMD3(repeating: 0.8), SIMD3(repeating: 1.2))
        return CIVector(x: CGFloat(gain.x), y: CGFloat(gain.y), z: CGFloat(gain.z))
    }

    /// AI 融合时给图片模型的指令：只调整光线、补影子，主体本身不变
    static let blendPrompt = """
    A subject was pasted into this photo inside the masked area. Blend it naturally into the scene: \
    match the lighting direction, brightness and color of the surroundings, soften the edges, and add a soft natural contact shadow where it touches the ground. \
    Keep the subject itself (its shape, face, identity and expression) unchanged. Do not add any new objects or text.
    """
}
