import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

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

    static func run(
        photo: Photo, strokes: [BrushStroke], prompt: String? = nil, folder: URL, provider: InpaintProvider
    ) async throws -> CleanupPatch {
        guard !strokes.isEmpty else { throw CleanupError.emptyStrokes }
        guard let source = PhotoRenderer.fullResolution(of: photo) else { throw CleanupError.unreadable }
        // 在已有修补的基础上继续消除，多次涂抹可以叠加
        let base = try PhotoRenderer.composite(source, patches: photo.cleanups ?? [], folder: folder)
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

        let patch = CleanupPatch(id: UUID(), rect: CGRect(
            x: crop.minX / imageSize.width, y: crop.minY / imageSize.height,
            width: crop.width / imageSize.width, height: crop.height / imageSize.height
        ))
        try FileManager.default.createDirectory(at: patchDirectory(folder: folder), withIntermediateDirectories: true)
        try PhotoRenderer.context.writePNGRepresentation(
            of: patchImage, to: patchURL(patch.id, folder: folder), format: .RGBA8, colorSpace: PhotoRenderer.sRGB
        )
        return patch
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
