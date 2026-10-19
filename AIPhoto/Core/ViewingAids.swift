import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// RGB 直方图，每个通道 256 档，已按最大值归一化到 0～1
struct Histogram: Equatable {
    var red: [Float]
    var green: [Float]
    var blue: [Float]
}

/// 拍摄参数（来自 Exif）
struct ShootingInfo: Equatable {
    var camera: String?
    var lens: String?
    var shutter: String?
    var aperture: String?
    var iso: String?
    var focalLength: String?
}

/// 选片时的看图辅助：直方图、合焦高亮、过曝欠曝提示、拍摄参数。
/// 都基于大图当前显示的图像计算，所以反映修复后的效果
enum ViewingAids {
    /// 阈值按屏幕显示值（sRGB 编码后）判断，用非线性工作空间，和人眼看到的一致
    private static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        .cacheIntermediates: false,
    ])

    /// 合焦高亮的颜色：亲子照里常见红色衣服、肤色，用绿色更醒目
    private static let peakingColor = CIColor(red: 0.1, green: 1, blue: 0.3)

    static func histogram(of image: CGImage) -> Histogram? {
        let width = 256, height = max(1, 256 * image.height / max(1, image.width))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var r = [Float](repeating: 0, count: 256), g = r, b = r
        for i in stride(from: 0, to: pixels.count, by: 4) {
            r[Int(pixels[i])] += 1
            g[Int(pixels[i + 1])] += 1
            b[Int(pixels[i + 2])] += 1
        }
        // 两端的溢出档常常极高，按中间档的最大值归一化，让主体形状看得清；两端会被截到顶
        let peak = max(1, (1..<255).map { max(r[$0], g[$0], b[$0]) }.max() ?? 1)
        func normalize(_ values: [Float]) -> [Float] { values.map { min(1, $0 / peak) } }
        return Histogram(red: normalize(r), green: normalize(g), blue: normalize(b))
    }

    /// 合焦高亮：边缘强度超过阈值的地方描成绿色，其余透明。
    /// 计算前缩到长边 2000，叠加显示时按图片大小拉伸，足够看出焦点落在哪
    static func peakingMask(of image: CGImage) -> CGImage? {
        let source = downscaled(CIImage(cgImage: image), longEdge: 2000)
        let edges = source
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 4])
            .applyingFilter("CIMaximumComponent")
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.35])
        return colored(mask: edges, color: peakingColor, extent: source.extent)
    }

    /// 过曝（三个通道都 ≥ 0.98，即死白无细节）标红，欠曝（三个通道都 ≤ 0.01）标蓝。
    /// 不用"任一通道到顶"：饱和的红色衣服、红房子红通道会到顶，但并没有丢细节，实拍上会整片误报
    static func clippingMask(of image: CGImage) -> CGImage? {
        let source = downscaled(CIImage(cgImage: image), longEdge: 2000)
        let highlights = source.applyingFilter("CIMinimumComponent")
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.98])
        let shadows = source.applyingFilter("CIMaximumComponent")
            .applyingFilter("CIColorInvert")
            .applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.99])
        guard let red = colored(mask: highlights, color: CIColor(red: 1, green: 0.1, blue: 0.1), extent: source.extent),
              let blue = colored(mask: shadows, color: CIColor(red: 0.1, green: 0.4, blue: 1), extent: source.extent)
        else { return nil }
        let combined = CIImage(cgImage: red).composited(over: CIImage(cgImage: blue))
        return context.createCGImage(combined, from: source.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    private static func downscaled(_ image: CIImage, longEdge: CGFloat) -> CIImage {
        let scale = min(1, longEdge / max(image.extent.width, image.extent.height))
        guard scale < 1 else { return image }
        return image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
    }

    /// 灰度蒙版（白 = 标记）转成"指定颜色 + 蒙版作为透明度"的图层
    private static func colored(mask: CIImage, color: CIColor, extent: CGRect) -> CGImage? {
        let fill = CIImage(color: color).cropped(to: extent)
        let layer = fill.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
        return context.createCGImage(layer, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    static func shootingInfo(at url: URL) -> ShootingInfo? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let canon = props[kCGImagePropertyMakerCanonDictionary] as? [CFString: Any] ?? [:]

        var info = ShootingInfo()
        info.camera = (tiff[kCGImagePropertyTIFFModel] as? String) ?? (canon["ImageType" as CFString] as? String)
        info.lens = (exif[kCGImagePropertyExifLensModel] as? String) ?? (canon["LensModel" as CFString] as? String)
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            info.shutter = time >= 1 ? String(format: "%.1f 秒", time) : "1/\(Int((1 / time).rounded())) 秒"
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { info.aperture = String(format: "f/%.1f", f) }
        // CR3 的 Exif 里可能没有 ISOSpeedRatings，改读推荐曝光指数
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
            ?? (exif[kCGImagePropertyExifRecommendedExposureIndex] as? Int)
        info.iso = iso.map { "ISO \($0)" }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { info.focalLength = "\(Int(focal.rounded())) mm" }
        return info
    }
}
