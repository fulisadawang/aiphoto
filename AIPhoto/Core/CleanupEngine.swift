import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// 云端补全服务的统一接口：输入局部图和蒙版（白色为要处理的区域），返回补好的局部图。
/// prompt 为 nil 时去掉蒙版内的物体；对话改图的重画会传入具体指令
protocol InpaintProvider: Sendable {
    func inpaint(image: CGImage, mask: CGImage, prompt: String?) async throws -> CGImage
}

/// 去杂物：只把涂抹区域附近裁一块送去补全，结果羽化后贴回，原图其余像素保持不变
enum CleanupEngine {
    /// 上传给服务的局部图最长边，多数补全服务在 1024 左右效果和速度最好
    static let uploadMaxPixel = 1024
    /// 涂抹区域四周额外带上的上下文比例，让模型看清周围纹理
    static let contextPadding = 0.6
    static let minCropPixels = 384.0

    enum CleanupError: LocalizedError {
        case emptyStrokes
        case unreadable
        case render
        var errorDescription: String? {
            switch self {
            case .emptyStrokes: "请先用画笔涂抹要去掉的物体"
            case .unreadable: "无法读取原图"
            case .render: "生成局部图或蒙版失败"
            }
        }
    }

    static func patchDirectory(folder: URL) -> URL {
        folder.appendingPathComponent(".aiphoto/patches")
    }

    static func patchURL(_ id: UUID, folder: URL) -> URL {
        patchDirectory(folder: folder).appendingPathComponent("\(id.uuidString).png")
    }

    /// 在已有修补的基础上继续消除，多次涂抹可以叠加
    private static func base(of photo: Photo, folder: URL) throws -> CIImage {
        guard let source = PhotoRenderer.fullResolution(of: photo) else { throw CleanupError.unreadable }
        return try PhotoRenderer.composite(source, patches: photo.cleanups ?? [], folder: folder)
    }

    static func run(
        photo: Photo, strokes: [BrushStroke], prompt: String? = nil, folder: URL, provider: InpaintProvider
    ) async throws -> CleanupPatch {
        guard !strokes.isEmpty else { throw CleanupError.emptyStrokes }
        let base = try base(of: photo, folder: folder)
        let imageSize = base.extent.size
        let crop = cropRect(for: strokes, imageSize: imageSize)

        let ciCrop = CGRect(
            x: base.extent.minX + crop.minX, y: base.extent.minY + imageSize.height - crop.maxY,
            width: crop.width, height: crop.height
        )
        guard let cropImage = PhotoRenderer.context.createCGImage(
            base, from: ciCrop, format: .RGBA8, colorSpace: PhotoRenderer.sRGB
        ) else { throw CleanupError.render }

        let scale = min(1, Double(uploadMaxPixel) / max(crop.width, crop.height))
        let uploadSize = CGSize(width: (crop.width * scale).rounded(), height: (crop.height * scale).rounded())
        guard let uploadImage = resize(cropImage, to: uploadSize),
              let uploadMask = drawMask(strokes, crop: crop, imageSize: imageSize, size: uploadSize, grow: 1.1)
        else { throw CleanupError.render }

        let filled = try await provider.inpaint(image: uploadImage, mask: uploadMask, prompt: prompt)

        // 结果放大回原始分辨率，只保留涂抹区域（边缘羽化），其余部分仍是原图像素
        guard let filledFull = resize(filled, to: crop.size),
              let hardMask = drawMask(strokes, crop: crop, imageSize: imageSize, size: crop.size, grow: 1.25)
        else { throw CleanupError.render }
        let matched = colorMatched(CIImage(cgImage: filledFull), to: CIImage(cgImage: cropImage), outside: CIImage(cgImage: hardMask))
        let featherSigma = max(2, Double(strokes.map(\.radius).max() ?? 0) * imageSize.width * 0.2)
        let feathered = CIImage(cgImage: hardMask).clampedToExtent()
            .applyingGaussianBlur(sigma: featherSigma)
            .cropped(to: CGRect(origin: .zero, size: crop.size))
        let patchImage = matched.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: feathered,
        ]).cropped(to: CGRect(origin: .zero, size: crop.size))

        return try save(patchImage, crop: crop, imageSize: imageSize, method: .ai, strokes: strokes, folder: folder)
    }

    private static func save(
        _ patchImage: CIImage, crop: CGRect, imageSize: CGSize, method: CleanupMethod, strokes: [BrushStroke], folder: URL
    ) throws -> CleanupPatch {
        let patch = CleanupPatch(id: UUID(), rect: CGRect(
            x: crop.minX / imageSize.width, y: crop.minY / imageSize.height,
            width: crop.width / imageSize.width, height: crop.height / imageSize.height
        ), method: method, strokes: strokes)
        try FileManager.default.createDirectory(at: patchDirectory(folder: folder), withIntermediateDirectories: true)
        try PhotoRenderer.context.writePNGRepresentation(
            of: patchImage, to: patchURL(patch.id, folder: folder), format: .RGBA8, colorSpace: PhotoRenderer.sRGB
        )
        return patch
    }

    // MARK: - 本机补（第 19.2 节）

    /// 面积小于画面这个比例才自动走本机。方案定的 1%；2026-10-22 实拍对比：0.5%～1% 的婴儿车、桌子本机补出来是一团糊的树丛纹理，
    /// 0.5% 以下的小车、水桶补得干净，所以收到 0.5%
    static let localMaxArea = 0.005
    /// 周围一圈里「成片直线」像素超过这个比例算有结构（窗框、栏杆、水边），本机容易补错位，交给 AI。
    /// 2026-10-22 实拍：0.11 的一处把池塘边线补断了，0.09 的小车补得干净，取 0.10
    static let localMaxStructure = 0.10
    /// 本机补时洞的最长边超过这个像素数先缩小再补：PatchMatch 的耗时随面积涨，强制本机补大块时防止卡很久
    static let localMaxHolePixels = 700.0

    /// 自动选择的依据，验证时打印用
    struct LocalCheck {
        /// 涂抹面积占整张画面的比例
        let area: Double
        /// 周围一圈里成片直线像素的比例
        let structure: Double
        var suitable: Bool { area < localMaxArea && structure <= localMaxStructure }
    }

    /// 小、周围是纹理（草地、地面、墙面、天空）的在本机补完返回修补块；不合适返回 nil，交给 AI
    static func runLocalIfSuitable(photo: Photo, strokes: [BrushStroke], folder: URL) throws -> CleanupPatch? {
        guard !strokes.isEmpty else { throw CleanupError.emptyStrokes }
        let base = try base(of: photo, folder: folder)
        guard try check(base: base, strokes: strokes).suitable else { return nil }
        return try localPatch(base: base, strokes: strokes, folder: folder)
    }

    /// 不管大小都在本机补（用户点了「用本机重来」）
    static func runLocal(photo: Photo, strokes: [BrushStroke], folder: URL) throws -> CleanupPatch {
        guard !strokes.isEmpty else { throw CleanupError.emptyStrokes }
        return try localPatch(base: try base(of: photo, folder: folder), strokes: strokes, folder: folder)
    }

    static func check(photo: Photo, strokes: [BrushStroke], folder: URL) throws -> LocalCheck {
        try check(base: try base(of: photo, folder: folder), strokes: strokes)
    }

    private static func check(base: CIImage, strokes: [BrushStroke]) throws -> LocalCheck {
        let imageSize = base.extent.size
        let crop = localCrop(for: strokes, imageSize: imageSize)
        // 结构判断不需要细节，缩到最长边 256 算，快
        let scale = min(1, 256 / max(crop.width, crop.height))
        let size = CGSize(width: max(1, (crop.width * scale).rounded()), height: max(1, (crop.height * scale).rounded()))
        guard let cropImage = render(base, crop: crop),
              let small = resize(cropImage, to: size),
              let mask = drawMask(strokes, crop: crop, imageSize: imageSize, size: size, grow: 1.25),
              let fullMask = drawMask(strokes, crop: crop, imageSize: imageSize, size: crop.size, grow: 1.25)
        else { throw CleanupError.render }
        let holeArea = Double(StructureMeter.count(fullMask)) / Double(imageSize.width * imageSize.height)
        return LocalCheck(area: holeArea, structure: StructureMeter.ringStructure(small, hole: mask))
    }

    private static func localPatch(base: CIImage, strokes: [BrushStroke], folder: URL) throws -> CleanupPatch {
        let imageSize = base.extent.size
        let crop = localCrop(for: strokes, imageSize: imageSize)
        guard let cropImage = render(base, crop: crop),
              let strokeMask = drawMask(strokes, crop: crop, imageSize: imageSize, size: crop.size, grow: 1.25)
        else { throw CleanupError.render }

        let holeSide = strokeBounds(strokes, imageSize: imageSize).insetBy(dx: -1, dy: -1).size
        let scale = min(1, localMaxHolePixels / max(holeSide.width, holeSide.height))
        // 实拍发现：不排除人时，会把孩子的皮肤、帽子拼进洞里（2026-10-22 白色水桶两例）
        let people = peopleMask(cropImage)
        // 找杂物的框常压到旁边的人（实拍：黄色椅子的框盖住了后面大人的腿）：大半在框外的人不补。
        // 整个在框里的（路人、被认成人的婴儿车）照常去掉
        let adjacent = people.flatMap { PeopleSplit.adjacent($0, hole: strokeMask) }
        let hardMask = adjacent.flatMap { subtract($0, from: strokeMask) } ?? strokeMask
        let filled: CGImage
        if scale < 1 {
            let size = CGSize(width: (crop.width * scale).rounded(), height: (crop.height * scale).rounded())
            guard let small = resize(cropImage, to: size),
                  let smallMask = resizeGray(hardMask, to: size),
                  let smallFilled = LocalHealer.fill(small, hole: smallMask, exclude: people.flatMap { resizeGray($0, to: size) }),
                  let upscaled = resize(smallFilled, to: crop.size)
            else { throw LocalError.failed }
            filled = upscaled
        } else {
            guard let result = LocalHealer.fill(cropImage, hole: hardMask, exclude: people) else { throw LocalError.failed }
            filled = result
        }

        // 补好的颜色已和四周对齐，只轻微羽化边缘；蒙版外仍是原图像素
        let featherSigma = max(1.5, Double(strokes.map(\.radius).max() ?? 0) * imageSize.width * 0.08)
        let feathered = CIImage(cgImage: hardMask).clampedToExtent()
            .applyingGaussianBlur(sigma: featherSigma)
            .cropped(to: CGRect(origin: .zero, size: crop.size))
        let patchImage = CIImage(cgImage: filled).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: feathered,
        ]).cropped(to: CGRect(origin: .zero, size: crop.size))
        return try save(patchImage, crop: crop, imageSize: imageSize, method: .local, strokes: strokes, folder: folder)
    }

    // MARK: - 祛瑕疵（第 19.1 节）

    /// 祛瑕疵的修补块名称，列表里显示、「用 AI 重来」时据此换成修皮肤的指令
    static let blemishName = "瑕疵"
    /// 祛瑕疵交给 AI 重画时的指令（用户 2026-10-22 确认允许，会花钱）
    static let blemishPrompt = "Remove the skin blemish (bump, scratch, spot, food crumb) inside the masked area. Keep the same person, the same skin tone and natural skin texture. Do not change anything else."
    /// 修复画笔模式：「借附近最像的一块」专为皮肤这类有细纹理的表面设计；有近脸实拍后再和「按内容补」比较
    static let blemishHealMode = LocalHealer.HealMode.proximity

    /// 用修复画笔修掉笔迹盖住的瑕疵，结果存成修补块
    static func runHeal(photo: Photo, strokes: [BrushStroke], folder: URL) throws -> CleanupPatch {
        guard !strokes.isEmpty else { throw CleanupError.emptyStrokes }
        let base = try base(of: photo, folder: folder)
        let imageSize = base.extent.size
        let bounds = strokeBounds(strokes, imageSize: imageSize)
        // 修复画笔要在四周找最吻合的一块皮肤（最远约 2.8 个工作框），留够余地
        let margin = max(48, max(bounds.width, bounds.height) * 3)
        let crop = bounds.insetBy(dx: -margin, dy: -margin).intersection(CGRect(origin: .zero, size: imageSize)).integral
        guard let cropImage = render(base, crop: crop),
              let hard = drawMask(strokes, crop: crop, imageSize: imageSize, size: crop.size, grow: 1.0)
        else { throw CleanupError.render }
        // 边缘留一点渐变，修复强度从里到外过渡
        let edge = max(1, Double(strokes.map(\.radius).max() ?? 0) * imageSize.width * 0.15)
        let soft = CIImage(cgImage: hard).clampedToExtent().applyingGaussianBlur(sigma: edge)
            .cropped(to: CGRect(origin: .zero, size: crop.size))
        guard let coverage = PhotoRenderer.context.createCGImage(soft, from: soft.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()),
              let healed = LocalHealer.heal(cropImage, coverage: coverage, mode: blemishHealMode)
        else { throw LocalError.failed }
        // 修复强度为 0 的地方就是原图，按放大一圈的蒙版取出贴回
        let keep = CIImage(cgImage: hard).clampedToExtent().applyingGaussianBlur(sigma: edge * 3)
            .cropped(to: CGRect(origin: .zero, size: crop.size))
        let patchImage = CIImage(cgImage: healed).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: keep,
        ]).cropped(to: CGRect(origin: .zero, size: crop.size))
        return try save(patchImage, crop: crop, imageSize: imageSize, method: .local, strokes: strokes, folder: folder)
    }

    /// 局部图里的人（孩子、大人、路人），与局部图同尺寸、白色为人，外扩几像素盖住发丝边缘。没有人或识别失败返回 nil
    private static func peopleMask(_ image: CGImage) -> CGImage? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let buffer = request.results?.first?.pixelBuffer
        else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        let scaled = mask.transformed(by: CGAffineTransform(
            scaleX: CGFloat(image.width) / mask.extent.width, y: CGFloat(image.height) / mask.extent.height
        ))
        let grown = scaled.applyingFilter("CIMorphologyMaximum", parameters: [
            kCIInputRadiusKey: max(2, Double(max(image.width, image.height)) * 0.006),
        ]).cropped(to: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return PhotoRenderer.context.createCGImage(grown, from: grown.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    /// 蒙版 mask 减去 cut（都是同尺寸灰度图）
    private static func subtract(_ cut: CGImage, from mask: CGImage) -> CGImage? {
        let result = CIImage(cgImage: mask).applyingFilter("CIMultiplyCompositing", parameters: [
            kCIInputBackgroundImageKey: CIImage(cgImage: cut).applyingFilter("CIColorInvert"),
        ])
        return PhotoRenderer.context.createCGImage(result, from: CGRect(x: 0, y: 0, width: mask.width, height: mask.height),
                                                   format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
    }

    private static func resizeGray(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    enum LocalError: LocalizedError {
        case failed
        var errorDescription: String? { "本机修补失败，可以点「用 AI 重来」" }
    }

    /// 笔迹包围盒（按 1.25 倍笔触），像素坐标（原点左上）
    private static func strokeBounds(_ strokes: [BrushStroke], imageSize: CGSize) -> CGRect {
        var bounds = CGRect.null
        for stroke in strokes {
            let radius = stroke.radius * imageSize.width * 1.25
            for point in stroke.points {
                let center = CGPoint(x: point.x * imageSize.width, y: point.y * imageSize.height)
                bounds = bounds.union(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
        }
        return bounds
    }

    /// 本机补的局部图：洞的四周各留出一个洞宽（至少 64 像素）供借纹理，与 patch_fill 自己的取材范围一致
    private static func localCrop(for strokes: [BrushStroke], imageSize: CGSize) -> CGRect {
        let bounds = strokeBounds(strokes, imageSize: imageSize)
        let margin = max(64, max(bounds.width, bounds.height))
        return bounds.insetBy(dx: -margin, dy: -margin)
            .intersection(CGRect(origin: .zero, size: imageSize)).integral
    }

    private static func render(_ base: CIImage, crop: CGRect) -> CGImage? {
        let imageSize = base.extent.size
        let ciCrop = CGRect(
            x: base.extent.minX + crop.minX, y: base.extent.minY + imageSize.height - crop.maxY,
            width: crop.width, height: crop.height
        )
        return PhotoRenderer.context.createCGImage(base, from: ciCrop, format: .RGBA8, colorSpace: PhotoRenderer.sRGB)
    }

    /// 笔迹包围盒加上下文边距，像素坐标（原点左上）。
    /// 尽量裁成正方形：补全模型多输出正方形，非正方形贴回时会被拉伸；贴近画面边缘时整体平移而不是截断
    static func cropRect(for strokes: [BrushStroke], imageSize: CGSize) -> CGRect {
        var bounds = CGRect.null
        for stroke in strokes {
            let radius = stroke.radius * imageSize.width
            for point in stroke.points {
                let center = CGPoint(x: point.x * imageSize.width, y: point.y * imageSize.height)
                bounds = bounds.union(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
        }
        let side = min(
            max(max(bounds.width, bounds.height) * (1 + contextPadding * 2), minCropPixels),
            min(imageSize.width, imageSize.height)
        )
        let x = min(max(0, bounds.midX - side / 2), imageSize.width - side)
        let y = min(max(0, bounds.midY - side / 2), imageSize.height - side)
        // 涂抹范围比短边还大时只能放宽为长方形
        let crop = CGRect(x: x, y: y, width: side, height: side).union(bounds)
        return crop.intersection(CGRect(origin: .zero, size: imageSize)).integral
    }

    /// 生成式模型常整体偏色。用蒙版外区域（新旧两图内容相同）的平均色算出逐通道增益，把结果校回原图色调，避免贴回后出现色差边
    static func colorMatched(_ result: CIImage, to original: CIImage, outside mask: CIImage) -> CIImage {
        let keep = mask.applyingFilter("CIColorInvert")
        func average(_ image: CIImage) -> SIMD3<Float>? {
            // 只统计蒙版外：先把蒙版内置黑，再用面积平均除以保留比例
            let masked = image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .black).cropped(to: image.extent),
                kCIInputMaskImageKey: keep,
            ])
            guard let color = areaAverage(masked), let coverage = areaAverage(keep), coverage.x > 0.05 else { return nil }
            return color / coverage.x
        }
        guard let target = average(original), let current = average(result), current.min() > 0.001 else { return result }
        let gain = target / current
        return result.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: CGFloat(gain.x), y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: CGFloat(gain.y), z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(gain.z), w: 0),
        ])
    }

    private static func areaAverage(_ image: CIImage) -> SIMD3<Float>? {
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        PhotoRenderer.context.render(
            average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        )
        return SIMD3(pixel[0], pixel[1], pixel[2])
    }

    /// 白色为涂抹区域的灰度蒙版；grow 略放大笔触，盖住物体边缘的残影
    static func drawMask(
        _ strokes: [BrushStroke], crop: CGRect, imageSize: CGSize, size: CGSize, grow: CGFloat
    ) -> CGImage? {
        let width = Int(size.width), height = Int(size.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(gray: 1, alpha: 1)
        context.setFillColor(gray: 1, alpha: 1)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let scaleX = size.width / crop.width, scaleY = size.height / crop.height
        func map(_ point: CGPoint) -> CGPoint {
            // CGContext 原点在左下，需要翻转 y
            CGPoint(
                x: (point.x * imageSize.width - crop.minX) * scaleX,
                y: size.height - (point.y * imageSize.height - crop.minY) * scaleY
            )
        }
        for stroke in strokes {
            let radius = stroke.radius * imageSize.width * scaleX * grow
            guard let first = stroke.points.first else { continue }
            if stroke.points.count == 1 {
                let center = map(first)
                context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                continue
            }
            context.setLineWidth(radius * 2)
            context.beginPath()
            context.move(to: map(first))
            for point in stroke.points.dropFirst() { context.addLine(to: map(point)) }
            context.strokePath()
        }
        return context.makeImage()
    }

    static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        if image.width == Int(size.width), image.height == Int(size.height) { return image }
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: PhotoRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
