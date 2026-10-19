import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageLoader {
    /// 按长边缩放读取图片。RAW 优先用内嵌预览，内嵌预览太小时才完整解码
    static func image(at url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        ]
        let target = min(maxPixel, longEdge(of: source) ?? maxPixel)
        if let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
           max(thumb.width, thumb.height) >= Int(Double(target) * 0.8) {
            return thumb
        }
        options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = nil
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// 修图用的底图（传入 Photo.editURL）：只有 RAW 时用 CIRAWFilter 解码，与导出成片一致；JPG 同 image(at:)。
    /// RAW 内嵌预览是相机套了照片风格的 JPG，和 RAW 解码观感不同，纯 RAW 照片不能拿它当底图
    static func editBase(at url: URL, maxPixel: Int) -> CGImage? {
        guard PhotoScanner.rawExtensions.contains(url.pathExtension.lowercased()),
              let raw = CIRAWFilter(imageURL: url)
        else { return image(at: url, maxPixel: maxPixel) }
        raw.scaleFactor = Float(min(1, Double(maxPixel) / max(raw.nativeSize.width, raw.nativeSize.height)))
        guard let output = raw.outputImage else { return nil }
        return PhotoRenderer.context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: PhotoRenderer.sRGB)
    }

    /// 方向转正后的原图像素尺寸（只读元数据，不解码）
    static func orientedPixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // 方向 5～8 表示旋转了 90°，宽高互换
        let rotated = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        return rotated ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    static func captureDate(at url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String,
              let date = exifFormatter.date(from: text)
        else { return nil }
        // 连拍同一秒内有多张，靠亚秒排序
        let subsecond = (exif[kCGImagePropertyExifSubsecTimeOriginal] as? String).flatMap { Double("0." + $0) } ?? 0
        return date.addingTimeInterval(subsecond)
    }

    static func jpegData(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func longEdge(of source: CGImageSource) -> Int? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return max(width, height)
    }

    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter
    }()
}

/// 缩略图与大图共用的内存缓存，按像素字节数限制总量
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, CGImage>()

    private init() {
        cache.totalCostLimit = 1_200_000_000
    }

    func cached(_ url: URL, maxPixel: Int, editBase: Bool = false) -> CGImage? {
        cache.object(forKey: key(url, maxPixel, editBase))
    }

    func load(_ url: URL, maxPixel: Int, editBase: Bool = false) async -> CGImage? {
        let key = key(url, maxPixel, editBase)
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            editBase ? ImageLoader.editBase(at: url, maxPixel: maxPixel) : ImageLoader.image(at: url, maxPixel: maxPixel)
        }.value
        if let image {
            cache.setObject(image, forKey: key, cost: image.width * image.height * 4)
        }
        return image
    }

    private func key(_ url: URL, _ maxPixel: Int, _ editBase: Bool) -> NSString {
        "\(editBase ? "edit" : "view")|\(maxPixel)|\(url.path)" as NSString
    }
}
