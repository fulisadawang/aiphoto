import CoreGraphics
import CoreImage
import Foundation
import ImageIO

enum PhotoRenderer {
    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .cacheIntermediates: false,
    ])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    enum RenderError: LocalizedError {
        case missingPatch(UUID)
        var errorDescription: String? {
            switch self {
            case .missingPatch(let id): "去杂物的修补文件丢失（\(id.uuidString.prefix(8))），请撤销后重新消除"
            }
        }
    }

    /// 在已缩放的预览图上叠加去杂物结果并套用调色，用于界面显示
    static func render(
        _ image: CGImage, edit: EditSettings?, faces: [FaceInfo], patches: [CleanupPatch], folder: URL
    ) throws -> CGImage? {
        let patched = try composite(CIImage(cgImage: image), patches: patches, folder: folder)
        let output = (edit ?? .neutral).apply(to: patched, faces: faces)
        return context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: sRGB)
    }

    /// 修补块存的是归一化区域，预览图和全尺寸原图都能直接按比例贴回
    static func composite(_ image: CIImage, patches: [CleanupPatch], folder: URL) throws -> CIImage {
        let extent = image.extent
        var output = image
        for patch in patches {
            guard let piece = CIImage(contentsOf: CleanupEngine.patchURL(patch.id, folder: folder)) else {
                throw RenderError.missingPatch(patch.id)
            }
            let target = CGRect(
                x: extent.minX + patch.rect.minX * extent.width,
                y: extent.minY + (1 - patch.rect.maxY) * extent.height,
                width: patch.rect.width * extent.width,
                height: patch.rect.height * extent.height
            )
            let placed = piece
                .transformed(by: CGAffineTransform(
                    scaleX: target.width / piece.extent.width, y: target.height / piece.extent.height
                ))
                .transformed(by: CGAffineTransform(translationX: target.minX, y: target.minY))
            output = placed.composited(over: output)
        }
        return output
    }

    /// 全尺寸修图底图，与 Photo.editURL 一致：有相机 JPG 用 JPG，只有 RAW 时完整解码 RAW
    static func fullResolution(of photo: Photo) -> CIImage? {
        if let jpg = photo.renderedURL {
            return CIImage(contentsOf: jpg, options: [.applyOrientationProperty: true])
        }
        guard let raw = photo.rawURL else { return nil }
        return CIRAWFilter(imageURL: raw)?.outputImage
    }

    static func exportJPEG(_ photo: Photo, folder: URL, to url: URL, quality: Double) throws {
        guard let source = fullResolution(of: photo) else { throw AnalyzerError.unreadable(photo.displayURL) }
        let patched = try composite(source, patches: photo.cleanups ?? [], folder: folder)
        var image = (photo.edit ?? .neutral).apply(to: patched, faces: photo.analysis?.faces ?? [])
        // 方向已经应用到像素上，元数据里的方向要复位，否则看图软件会再转一次
        var properties = source.properties
        properties[kCGImagePropertyOrientation as String] = 1
        image = image.settingProperties(properties)
        try context.writeJPEGRepresentation(
            of: image, to: url, colorSpace: sRGB,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality]
        )
    }
}
