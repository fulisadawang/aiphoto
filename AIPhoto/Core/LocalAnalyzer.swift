import Accelerate
import CoreGraphics
import Foundation
import Vision

enum LocalAnalyzer {
    /// 小于画面高度 2.5% 的人脸多是背景路人，不参与判断。
    /// 实拍纪实远景里孩子的脸常只占 3% 左右，门槛不能太高；太小的脸眼睛像素不够，闭眼判断会自动跳过
    static let minFaceHeight: CGFloat = 0.025
    static let gridSize = 16
    /// 两只眼的"深色区域高度 / 眼宽"都低于该值视为闭眼。
    /// 实测 Vision 的眼部关键点几乎不随眼皮开合变化，所以改为看像素：睁眼能看到有高度的深色虹膜，闭眼只剩一条睫毛线。
    /// 大笑眯眼也可能触发，只作提示，最终交给 AI 和人判断
    static let blinkRatio: Float = 0.18

    static func analyze(url: URL) throws -> LocalAnalysis {
        guard let image = ImageLoader.image(at: url, maxPixel: 1600) else {
            throw AnalyzerError.unreadable(url)
        }
        let luma = try LumaPlane(image: image)

        let landmarks = VNDetectFaceLandmarksRequest()
        let featurePrint = VNGenerateImageFeaturePrintRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([landmarks, featurePrint, humans])

        let faceObservations = (landmarks.results ?? []).filter { $0.boundingBox.height >= minFaceHeight }
        var qualities: [Float?] = Array(repeating: nil, count: faceObservations.count)
        if !faceObservations.isEmpty {
            let quality = VNDetectFaceCaptureQualityRequest()
            quality.inputFaceObservations = faceObservations
            try handler.perform([quality])
            if let results = quality.results, results.count == faceObservations.count {
                qualities = results.map(\.faceCaptureQuality)
            }
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        var faces = zip(faceObservations, qualities).map { observation, quality in
            let b = observation.boundingBox
            let openness = eyeOpenness(of: observation, luma: luma)
            return FaceInfo(
                box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height),
                quality: quality,
                eyeOpenness: openness,
                isBlinking: openness.map { $0 < blinkRatio } ?? false,
                features: featurePolygons(of: observation, imageSize: imageSize),
                shape: faceShape(of: observation, imageSize: imageSize)
            )
        }

        // 远景小脸在 1600 像素的分析图上眼睛只有几个像素，量不了；从原图裁出脸部重新定位眼睛再量。
        // 只有出现小脸的照片才多解码一次原图
        if faces.contains(where: { $0.eyeOpenness == nil }), let full = ImageLoader.image(at: url, maxPixel: 8000) {
            for index in faces.indices where faces[index].eyeOpenness == nil {
                guard let openness = try highResEyeOpenness(face: faces[index].box, in: full) else { continue }
                faces[index].eyeOpenness = openness
                faces[index].isBlinking = openness < blinkRatio
            }
        }

        // 纪实里背影、侧脸、远景很常见：没有人脸时取最大的人体框当主体
        let subject: CGRect? = faces.isEmpty
            ? (humans.results ?? []).max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
                .map { CGRect(x: $0.boundingBox.minX, y: 1 - $0.boundingBox.maxY, width: $0.boundingBox.width, height: $0.boundingBox.height) }
            : nil

        let laplacian = try luma.laplacian()
        let sharpness: Double
        if let face = faces.max(by: { $0.box.width * $0.box.height < $1.box.width * $1.box.height }) {
            sharpness = laplacian.variance(in: face.box.insetBy(dx: -face.box.width * 0.1, dy: -face.box.height * 0.1))
        } else if let subject {
            sharpness = laplacian.variance(in: subject)
        } else {
            sharpness = laplacian.sharpestTileVariance(grid: 6)
        }

        let exposure = try luma.exposureStats()
        let printData = try featurePrint.results?.first.map {
            try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true)
        }

        return LocalAnalysis(
            sharpness: sharpness,
            meanLuma: exposure.mean,
            highlightClip: exposure.highlight,
            shadowClip: exposure.shadow,
            faces: faces,
            subject: subject,
            sharpnessGrid: laplacian.gridVariances(size: LocalAnalyzer.gridSize),
            featurePrint: printData
        )
    }

    private static func featurePolygons(of face: VNFaceObservation, imageSize: CGSize) -> [[CGPoint]]? {
        guard let landmarks = face.landmarks else { return nil }
        let regions = [landmarks.leftEye, landmarks.rightEye, landmarks.leftEyebrow, landmarks.rightEyebrow, landmarks.outerLips]
        let polygons = regions.compactMap { region -> [CGPoint]? in
            guard let points = region?.pointsInImage(imageSize: imageSize), points.count > 2 else { return nil }
            return points.map { CGPoint(x: $0.x / imageSize.width, y: 1 - $0.y / imageSize.height) }
        }
        return polygons.isEmpty ? nil : polygons
    }

    static func faceShape(of face: VNFaceObservation, imageSize: CGSize) -> FaceShape? {
        guard let l = face.landmarks else { return nil }
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint]? {
            guard let points = region?.pointsInImage(imageSize: imageSize), !points.isEmpty else { return nil }
            return points.map { CGPoint(x: $0.x / imageSize.width, y: 1 - $0.y / imageSize.height) }
        }
        guard let contour = points(l.faceContour), let leftEye = points(l.leftEye), let rightEye = points(l.rightEye),
              let leftPupil = points(l.leftPupil)?.first, let rightPupil = points(l.rightPupil)?.first,
              let leftBrow = points(l.leftEyebrow), let rightBrow = points(l.rightEyebrow),
              let outer = points(l.outerLips), let inner = points(l.innerLips)
        else { return nil }
        return FaceShape(
            faceContour: contour, leftEye: leftEye, rightEye: rightEye, leftPupil: leftPupil, rightPupil: rightPupil,
            leftEyebrow: leftBrow, rightEyebrow: rightBrow, outerLips: outer, innerLips: inner
        )
    }

    /// 旧记录补测关键点：重新检测后按人脸框重叠度对应到已有的人脸，对不上的留空
    static func faceShapes(url: URL, boxes: [CGRect]) throws -> [FaceShape?] {
        guard let image = ImageLoader.image(at: url, maxPixel: 1600) else { throw AnalyzerError.unreadable(url) }
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let imageSize = CGSize(width: image.width, height: image.height)
        let detected = (request.results ?? []).map { observation in
            let b = observation.boundingBox
            return (box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), observation: observation)
        }
        return boxes.map { box in
            let best = detected.max { overlap($0.box, box) < overlap($1.box, box) }
            guard let best, overlap(best.box, box) > 0.5 else { return nil }
            return faceShape(of: best.observation, imageSize: imageSize)
        }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let i = inter.width * inter.height
        return i / (a.width * a.height + b.width * b.height - i)
    }

    /// 返回两只眼中较大的"深色区域高度 / 眼宽"，任意一只眼睁开就不算闭眼
    /// 在原图上裁出脸部（四周多留 40%）重新检测关键点并测量眼睛
    private static func highResEyeOpenness(face box: CGRect, in image: CGImage) throws -> Float? {
        let region = box.insetBy(dx: -box.width * 0.4, dy: -box.height * 0.4)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixels = CGRect(
            x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height),
            width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height)
        ).integral
        guard let crop = image.cropping(to: pixels) else { return nil }
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
        guard let face = (request.results ?? []).max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        else { return nil }
        return eyeOpenness(of: face, luma: try LumaPlane(image: crop))
    }

    private static func eyeOpenness(of face: VNFaceObservation, luma: LumaPlane) -> Float? {
        guard let landmarks = face.landmarks else { return nil }
        let imageSize = CGSize(width: luma.width, height: luma.height)
        let values = [landmarks.leftEye, landmarks.rightEye].compactMap { region -> Float? in
            guard let points = region?.pointsInImage(imageSize: imageSize),
                  let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
                  let minY = points.map(\.y).min(), let maxY = points.map(\.y).max()
            else { return nil }
            let eyeWidth = maxX - minX
            // 太小的眼睛像素不够，判断不可靠
            guard eyeWidth >= 12 else { return nil }
            // 左右只取中间 60%（虹膜所在），上下取眼宽的 0.8 倍；Vision 坐标原点在左下，转成行号
            let centerY = luma.height - Int((minY + maxY) / 2)
            let rows = max(0, centerY - Int(eyeWidth * 0.4))..<min(luma.height, centerY + Int(eyeWidth * 0.4))
            let columns = max(0, Int(minX + eyeWidth * 0.2))..<min(luma.width, Int(maxX - eyeWidth * 0.2))
            return luma.darkColumnHeight(rows: rows, columns: columns).map { Float($0 / eyeWidth) }
        }
        return values.max()
    }
}

enum AnalyzerError: LocalizedError {
    case unreadable(URL)
    case context
    case vImage(vImage_Error)

    var errorDescription: String? {
        switch self {
        case .unreadable(let url): "无法读取图片：\(url.lastPathComponent)"
        case .context: "无法创建灰度画布"
        case .vImage(let code): "图像计算失败（vImage \(code)）"
        }
    }
}

private func check(_ error: vImage_Error) throws {
    guard error == kvImageNoError else { throw AnalyzerError.vImage(error) }
}

/// 8 位灰度图，第 0 行对应画面顶部
struct LumaPlane {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(image: CGImage) throws {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw AnalyzerError.context }
        bytes = buffer
    }

    func exposureStats() throws -> (mean: Double, highlight: Double, shadow: Double) {
        var histogram = [vImagePixelCount](repeating: 0, count: 256)
        var source = bytes
        try source.withUnsafeMutableBytes { raw in
            var buffer = vImage_Buffer(
                data: raw.baseAddress, height: vImagePixelCount(height),
                width: vImagePixelCount(width), rowBytes: width
            )
            try check(vImageHistogramCalculation_Planar8(&buffer, &histogram, vImage_Flags(kvImageNoFlags)))
        }
        let total = Double(width * height)
        let weighted = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset) * Double($1.element) }
        let highlight = Double(histogram[250...].reduce(0, +)) / total
        let shadow = Double(histogram[...5].reduce(0, +)) / total
        return (weighted / total / 255, highlight, shadow)
    }

    /// 区域内以"最亮 5% 的 55%"为阈值，统计每列深色像素数，返回中位数
    func darkColumnHeight(rows: Range<Int>, columns: Range<Int>) -> Double? {
        guard rows.count > 2, columns.count > 2 else { return nil }
        var values: [UInt8] = []
        values.reserveCapacity(rows.count * columns.count)
        for y in rows { for x in columns { values.append(bytes[y * width + x]) } }
        values.sort()
        let threshold = Double(values[values.count * 95 / 100]) * 0.55
        var heights = columns.map { x in rows.reduce(0) { Double(bytes[$1 * width + x]) < threshold ? $0 + 1 : $0 } }
        heights.sort()
        return Double(heights[heights.count / 2])
    }

    func laplacian() throws -> FloatPlane {
        var source = [Float](repeating: 0, count: bytes.count)
        vDSP.convertElements(of: bytes, to: &source)
        var output = [Float](repeating: 0, count: bytes.count)
        let kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        try source.withUnsafeMutableBytes { src in
            try output.withUnsafeMutableBytes { dst in
                var srcBuffer = vImage_Buffer(
                    data: src.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size
                )
                var dstBuffer = vImage_Buffer(
                    data: dst.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.size
                )
                try check(vImageConvolve_PlanarF(
                    &srcBuffer, &dstBuffer, nil, 0, 0, kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend)
                ))
            }
        }
        return FloatPlane(width: width, height: height, values: output)
    }
}

struct FloatPlane {
    let width: Int
    let height: Int
    let values: [Float]

    /// rect 为归一化坐标（原点左上）
    func variance(in rect: CGRect) -> Double {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull else { return 0 }
        let x0 = Int(clipped.minX * CGFloat(width)), x1 = Int(clipped.maxX * CGFloat(width))
        let y0 = Int(clipped.minY * CGFloat(height)), y1 = Int(clipped.maxY * CGFloat(height))
        guard x1 - x0 > 2, y1 - y0 > 2 else { return 0 }

        var sum = 0.0, sumOfSquares = 0.0
        values.withUnsafeBufferPointer { pointer in
            for y in y0..<y1 {
                let row = UnsafeBufferPointer(rebasing: pointer[(y * width + x0)..<(y * width + x1)])
                sum += Double(vDSP.sum(row))
                sumOfSquares += Double(vDSP.sumOfSquares(row))
            }
        }
        let count = Double((x1 - x0) * (y1 - y0))
        let mean = sum / count
        return sumOfSquares / count - mean * mean
    }

    func gridVariances(size: Int) -> [Float] {
        let step = 1.0 / Double(size)
        var result: [Float] = []
        for gy in 0..<size {
            for gx in 0..<size {
                result.append(Float(variance(in: CGRect(x: Double(gx) * step, y: Double(gy) * step, width: step, height: step))))
            }
        }
        return result
    }

    /// 没有人脸时取第二清晰的区块：浅景深照片背景虚化是正常的，只看最清晰的部分；不取最大值是为了避开单个噪点区块
    func sharpestTileVariance(grid: Int) -> Double {
        let step = 1.0 / Double(grid)
        var variances: [Double] = []
        for gy in 0..<grid {
            for gx in 0..<grid {
                variances.append(variance(in: CGRect(x: Double(gx) * step, y: Double(gy) * step, width: step, height: step)))
            }
        }
        variances.sort(by: >)
        return variances[min(1, variances.count - 1)]
    }
}
