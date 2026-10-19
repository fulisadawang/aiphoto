import CoreGraphics
import CoreImage
import Foundation

/// 轻量皮肤处理：只作用在人脸区域，五官（眼、眉、嘴）挖空保持锐利，边缘羽化。
/// 不做强磨皮，孩子的皮肤质感要保留
enum SkinRetoucher {
    static func apply(to image: CIImage, faces: [FaceInfo], amount: Double) -> CIImage {
        // 没有五官轮廓（旧的分析记录）时不处理，避免把眼睛也磨糊
        let usable = faces.filter { $0.features != nil }
        guard amount > 0, !usable.isEmpty, let mask = makeMask(faces: usable, extent: image.extent) else { return image }

        let faceWidth = usable.map(\.box.width).max() ?? 0
        let sigma = max(1.5, faceWidth * image.extent.width * 0.012)
        let smooth = image.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: image.extent)
        // 只把高频细节衰减一部分：结果 = 原图 - 力度 × (原图 - 模糊)，留住毛孔级纹理
        let softened = smooth.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: image,
            kCIInputTimeKey: 1 - min(1, amount) * 0.6,
        ])
        return softened.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: mask,
        ])
    }

    /// 蒙版尺寸按长边 1024 生成后放大，羽化本来就会抹掉细节，没必要按全尺寸绘制
    private static func makeMask(faces: [FaceInfo], extent: CGRect) -> CIImage? {
        let scale = min(1, 1024 / max(extent.width, extent.height))
        let width = Int(extent.width * scale), height = Int(extent.height * scale)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * CGFloat(width), y: (1 - point.y) * CGFloat(height))
        }
        for face in faces {
            // 人脸框偏紧，向下多给一点覆盖下巴和脸颊
            let box = face.box
            let oval = CGRect(
                x: box.minX + box.width * 0.08, y: box.minY + box.height * 0.05,
                width: box.width * 0.84, height: box.height * 1.0
            )
            let a = map(CGPoint(x: oval.minX, y: oval.maxY)), b = map(CGPoint(x: oval.maxX, y: oval.minY))
            context.setFillColor(gray: 1, alpha: 1)
            context.fillEllipse(in: CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))

            context.setFillColor(gray: 0, alpha: 1)
            context.setStrokeColor(gray: 0, alpha: 1)
            context.setLineWidth(max(2, box.width * CGFloat(width) * 0.04))
            context.setLineJoin(.round)
            for polygon in face.features ?? [] {
                guard let first = polygon.first else { continue }
                context.beginPath()
                context.move(to: map(first))
                for point in polygon.dropFirst() { context.addLine(to: map(point)) }
                context.closePath()
                // 描边外扩，盖住睫毛和唇线
                context.drawPath(using: .fillStroke)
            }
        }
        guard let cgMask = context.makeImage() else { return nil }
        let featherSigma = Double(width) * 0.006
        return CIImage(cgImage: cgMask)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: featherSigma)
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}
