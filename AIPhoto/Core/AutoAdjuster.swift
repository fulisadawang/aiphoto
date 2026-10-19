import CoreGraphics
import CoreImage
import Foundation

/// 自动白平衡与曝光。目标是"干净自然"，不追求把每张都校成标准中性色
enum AutoAdjuster {
    /// 白平衡只校正 70%：室内暖光的氛围是纪实照片的一部分，完全校正会显得冷淡
    static let whiteBalanceStrength = 0.7
    /// 有人脸时把人脸亮度拉到该值（sRGB），儿童肤色在 0.55~0.65 之间比较通透
    static let faceTarget = 0.58
    static let sceneTarget = 0.46

    static func compute(url: URL, analysis: LocalAnalysis?) throws -> EditSettings {
        guard let image = ImageLoader.editBase(at: url, maxPixel: 256) else { throw AnalyzerError.unreadable(url) }
        let pixels = try SRGBPixels(image: image)

        var edit = EditSettings()
        if let neutral = pixels.neutralAverage() {
            let (temperature, tint) = try estimateIlluminant(linearRGB: neutral)
            // 在倒色温（mired）空间按比例回退，比直接插值开尔文更均匀
            let mired = 1e6 / 6500 + (1e6 / temperature - 1e6 / 6500) * whiteBalanceStrength
            edit.temperature = (1e6 / mired).rounded()
            edit.tint = (tint * whiteBalanceStrength).rounded()
        }

        let face = analysis?.mainFace
        let current = face.map { pixels.meanLuma(in: $0.box) } ?? pixels.meanLuma(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let target = face == nil ? sceneTarget : faceTarget
        if current > 0.01 {
            let ev = log2(pow(target, 2.2) / pow(current, 2.2)) * 0.8
            edit.exposure = (min(1.5, max(-1.5, ev)) * 100).rounded() / 100
        }

        if let analysis {
            if analysis.highlightClip > 0.02 { edit.highlights = -0.4 }
            if analysis.shadowClip > 0.05 { edit.shadows = 0.3 }
        }
        edit.vibrance = 0.15
        return edit
    }

    /// 搜索一个光源色温/色调，使中性像素的平均色经 CITemperatureAndTint 校正后最接近灰色
    private static func estimateIlluminant(linearRGB: (Double, Double, Double)) throws -> (Double, Double) {
        let color = CIImage(color: CIColor(
            red: linearRGB.0, green: linearRGB.1, blue: linearRGB.2,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        )!).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))

        func chroma(_ temperature: Double, _ tint: Double) -> Double {
            let corrected = color.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: temperature, y: tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
            var pixel = [Float](repeating: 0, count: 4)
            PhotoRenderer.context.render(
                corrected, toBitmap: &pixel, rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            )
            let g = max(Double(pixel[1]), 1e-4)
            return abs(Double(pixel[0]) / g - 1) + abs(Double(pixel[2]) / g - 1)
        }

        var best = (temperature: 6500.0, tint: 0.0, error: chroma(6500, 0))
        func search(temperatures: [Double], tints: [Double]) {
            for temperature in temperatures {
                for tint in tints {
                    let error = chroma(temperature, tint)
                    if error < best.error { best = (temperature, tint, error) }
                }
            }
        }
        search(temperatures: stride(from: 2500.0, through: 11000, by: 500).map { $0 },
               tints: stride(from: -60.0, through: 60, by: 10).map { $0 })
        let coarse = best
        search(temperatures: stride(from: coarse.temperature - 400, through: coarse.temperature + 400, by: 50).map { $0 },
               tints: stride(from: coarse.tint - 8, through: coarse.tint + 8, by: 2).map { $0 })
        return (best.temperature, best.tint)
    }
}

/// 8 位 sRGB 像素，第 0 行对应画面顶部
private struct SRGBPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(image: CGImage) throws {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw AnalyzerError.context }
        bytes = buffer
    }

    /// 低饱和、中等亮度的像素大概率是灰白物体，取其线性平均作为光源颜色；数量太少时不做白平衡
    func neutralAverage() -> (Double, Double, Double)? {
        var sum = (0.0, 0.0, 0.0)
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let r = Double(bytes[index]) / 255, g = Double(bytes[index + 1]) / 255, b = Double(bytes[index + 2]) / 255
            let high = max(r, g, b), low = min(r, g, b)
            guard high > 0.25, high < 0.95, (high - low) / high < 0.25 else { continue }
            sum.0 += pow(r, 2.2)
            sum.1 += pow(g, 2.2)
            sum.2 += pow(b, 2.2)
            count += 1
        }
        guard count > width * height / 50 else { return nil }
        return (sum.0 / Double(count), sum.1 / Double(count), sum.2 / Double(count))
    }

    /// rect 为归一化坐标（原点左上），返回 sRGB 亮度均值
    func meanLuma(in rect: CGRect) -> Double {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull else { return 0 }
        let x0 = Int(clipped.minX * CGFloat(width)), x1 = max(x0 + 1, Int(clipped.maxX * CGFloat(width)))
        let y0 = Int(clipped.minY * CGFloat(height)), y1 = max(y0 + 1, Int(clipped.maxY * CGFloat(height)))
        var sum = 0.0
        for y in y0..<min(y1, height) {
            for x in x0..<min(x1, width) {
                let index = (y * width + x) * 4
                sum += 0.2126 * Double(bytes[index]) + 0.7152 * Double(bytes[index + 1]) + 0.0722 * Double(bytes[index + 2])
            }
        }
        return sum / Double((min(y1, height) - y0) * (min(x1, width) - x0)) / 255
    }
}
