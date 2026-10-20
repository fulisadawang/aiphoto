import CoreGraphics
import CoreImage
import Foundation

/// 一张脸的人像修复力度，都是 0~1
struct PortraitAmounts: Codable, Equatable {
    var skin = 0.0
    var darkCircles = 0.0
    var eyeBrighten = 0.0
    var teeth = 0.0
    var faceSlim = 0.0
    var eyeEnlarge = 0.0

    var isActive: Bool { skin > 0 || darkCircles > 0 || eyeBrighten > 0 || teeth > 0 || faceSlim > 0 || eyeEnlarge > 0 }
    var hasGeometry: Bool { faceSlim > 0 || eyeEnlarge > 0 }
}

/// 本地人像修复：全部按 Vision 关键点定位，只动脸部，不上传。
/// 顺序：先在原始几何上做皮肤、黑眼圈、眼睛、牙齿，最后再瘦脸大眼，否则关键点和像素对不上。
///
/// 磨皮的蒙版生成移植自 YUCIHighPassSkinSmoothing（MIT，Copyright (c) 2016 Yu Ao，https://github.com/YuAo/YUCIHighPassSkinSmoothing）：
/// 绿蓝通道叠加 → 高反差 → 三次强光，得到"暗斑"蒙版，只把暗斑和毛孔阴影按曲线提亮，不整体模糊。
/// 瘦脸、大眼的变形思路参考 swift-face-beauty（MIT，Copyright (c) 2026 David Sherlock），按 macOS 15 可用的写法重写：
/// 大眼用径向放大；瘦脸改为把下颌轮廓点向脸中线平移（局部平移变形），不再用整块收缩，嘴和鼻子不会被挤变形
enum PortraitRetoucher {
    static func apply(to image: CIImage, faces: [FaceInfo], amounts: (Int) -> PortraitAmounts) -> CIImage {
        let extent = image.extent
        var output = image
        for (index, face) in faces.enumerated() {
            let a = amounts(index)
            guard a.isActive else { continue }
            output = retouchTone(output, face: face, amounts: a, extent: extent)
        }
        for (index, face) in faces.enumerated() {
            let a = amounts(index)
            guard a.hasGeometry, let shape = face.shape else { continue }
            output = reshape(output, geometry: FaceGeometry(shape: shape, box: face.box, extent: extent), amounts: a)
        }
        return output
    }

    // MARK: - 皮肤与局部调色

    private static func retouchTone(_ image: CIImage, face: FaceInfo, amounts a: PortraitAmounts, extent: CGRect) -> CIImage {
        // 旧记录没有完整关键点：只能按五官轮廓做皮肤，其他几项需要关键点
        guard let shape = face.shape else {
            guard a.skin > 0, let features = face.features else { return image }
            let region = workRegion(box: face.box, extent: extent)
            guard let mask = legacySkinMask(box: face.box, features: features, region: region, extent: extent) else { return image }
            let faceWidth = face.box.width * extent.width
            return smoothSkin(image, mask: mask, amount: a.skin, faceWidth: faceWidth, region: region)
        }

        let g = FaceGeometry(shape: shape, box: face.box, extent: extent)
        let region = workRegion(box: face.box, extent: extent)
        let reference = cheekColor(image, geometry: g)
        let key = skinKey.apply(extent: region, arguments: [image.cropped(to: region), reference])
            ?? CIImage(color: .white).cropped(to: region)
        var output = image

        if a.skin > 0, let shapeMask = skinMask(g, region: region) {
            output = smoothSkin(output, mask: multiply(shapeMask, key), amount: a.skin, faceWidth: g.faceWidth, region: region)
        }
        if a.darkCircles > 0, let mask = underEyeMask(g, region: region),
           let lifted = darkLift.apply(extent: region, arguments: [output.cropped(to: region), reference, a.darkCircles]) {
            output = blend(lifted, over: output, mask: multiply(mask, key))
        }
        if a.eyeBrighten > 0, let mask = polygonMask([g.leftEye, g.rightEye], region: region, feather: g.eyeWidth * 0.06) {
            // 只提亮：加对比和锐化会把睫毛、瞳孔压黑，拉满时眼睛像描了一圈黑边（实拍验证）
            let bright = output.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.eyeBrighten * 0.35])
            output = blend(bright, over: output, mask: mask)
        }
        if a.teeth > 0, let mask = polygonMask([g.innerLips], region: region, feather: g.mouthWidth * 0.03),
           let white = teethWhiten.apply(extent: region, arguments: [output.cropped(to: region), a.teeth]) {
            output = blend(white, over: output, mask: mask)
        }
        return output.cropped(to: extent)
    }

    /// 高反差暗斑提亮 + 少量高频衰减，力度由蒙版灰度控制
    private static func smoothSkin(_ image: CIImage, mask: CIImage, amount: Double, faceWidth: CGFloat, region: CGRect) -> CIImage {
        // YUCI 的半径 8 对应自拍里约 500 像素宽的脸，按脸宽等比换算
        let radius = max(1.5, faceWidth * 0.016)
        let source = image.clampedToExtent()
        let darker = source.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1])
        guard let overlay = gbOverlay.apply(extent: region, arguments: [darker.cropped(to: region)]) else { return image }
        let blurred = overlay.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: region)
        guard let highPass = highPass.apply(extent: region, arguments: [overlay, blurred]),
              let spots = maskBoost.apply(extent: region, arguments: [highPass]) else { return image }
        // YUCI 的提亮曲线过 (0,0)、(120,146)、(255,255)；CIToneCurve 要 5 个点，中间两点取同一条二次曲线上的值
        let curved = image.applyingFilter("CIToneCurve", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0),
            "inputPoint1": CIVector(x: 0.25, y: 0.327),
            "inputPoint2": CIVector(x: 120.0 / 255, y: 146.0 / 255),
            "inputPoint3": CIVector(x: 0.75, y: 0.827),
            "inputPoint4": CIVector(x: 1, y: 1),
        ])
        // 暗斑处（蒙版黑）用提亮后的颜色，其他地方保持原样
        let lifted = image.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: curved, kCIInputMaskImageKey: spots,
        ])
        // 再衰减一部分高频，力度比旧版低，毛孔纹理要留住
        let low = source.applyingGaussianBlur(sigma: radius * 0.8).cropped(to: region)
        let softened = low.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: lifted.cropped(to: region), kCIInputTimeKey: 0.5,
        ])
        return blend(softened, over: image, mask: scaled(mask, by: amount)).cropped(to: image.extent)
    }

    // MARK: - 瘦脸、大眼

    private static func reshape(_ image: CIImage, geometry g: FaceGeometry, amounts a: PortraitAmounts) -> CIImage {
        let extent = image.extent
        var output = image
        if a.faceSlim > 0 {
            let contour = g.faceContour
            let n = contour.count
            let last = Double(n - 1)
            var picks: [Int] = []
            // 取轮廓 12%~32% 处：脸颊下半到下颌角，离嘴角足够远，嘴不会被挤歪
            for f in [0.12, 0.22, 0.32] {
                picks.append(Int(last * f))
                picks.append(Int(last * (1 - f)))
            }
            let center = g.faceCenter
            let shift = g.faceWidth * 0.035 * a.faceSlim
            let radius = g.faceWidth * 0.22
            var args: [Any] = []
            for i in picks {
                let p = contour[i]
                let dx = center.x - p.x
                let move = CGPoint(x: dx > 0 ? shift : -shift, y: 0)
                args.append(CIVector(x: p.x, y: p.y, z: move.x, w: move.y))
            }
            args.append(radius)
            if let warped = slimWarp.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -radius, dy: -radius) },
                                           image: output.clampedToExtent(), arguments: args) {
                output = warped.cropped(to: extent)
            }
        }
        if a.eyeEnlarge > 0 {
            let radius = g.eyeWidth * 1.0
            // 拉满时眼睛中心放大约 1.18 倍，再大孩子的脸会失真
            let strength = a.eyeEnlarge * 0.15
            let args: [Any] = [
                CIVector(cgPoint: g.leftEyeCenter), CIVector(cgPoint: g.rightEyeCenter), radius, strength,
            ]
            if let warped = eyeWarp.apply(extent: extent, roiCallback: { _, rect in rect.insetBy(dx: -radius, dy: -radius) },
                                          image: output.clampedToExtent(), arguments: args) {
                output = warped.cropped(to: extent)
            }
        }
        return output
    }

    // MARK: - 蒙版

    /// 处理范围：人脸框四周放大，盖住额头和下颌，避免整张图参与计算
    private static func workRegion(box: CGRect, extent: CGRect) -> CGRect {
        let px = CGRect(
            x: extent.minX + box.minX * extent.width, y: extent.minY + (1 - box.maxY) * extent.height,
            width: box.width * extent.width, height: box.height * extent.height
        )
        return px.insetBy(dx: -px.width * 0.4, dy: -px.height * 0.5).intersection(extent).integral
    }

    /// 脸部轮廓（下巴到两侧太阳穴）加推算的额头，挖掉眼、眉、嘴
    private static func skinMask(_ g: FaceGeometry, region: CGRect) -> CIImage? {
        guard let canvas = MaskCanvas(region: region), let first = g.faceContour.first, let last = g.faceContour.last else { return nil }
        let ctx = canvas.context
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.beginPath()
        ctx.move(to: canvas.point(first))
        for p in g.faceContour.dropFirst() { ctx.addLine(to: canvas.point(p)) }
        // 额头：眉毛以上再留"眉到下巴"距离的 30%，用二次曲线从轮廓一端拱到另一端
        let top = g.browTop + (g.browTop - g.chin.y) * 0.3
        let control = CGPoint(x: (first.x + last.x) / 2, y: 2 * top - (first.y + last.y) / 2)
        ctx.addQuadCurve(to: canvas.point(first), control: canvas.point(control))
        ctx.fillPath()
        canvas.cutOut([g.leftEye, g.rightEye], stroke: g.eyeWidth * 0.35)
        canvas.cutOut([g.leftEyebrow, g.rightEyebrow], stroke: g.eyeWidth * 0.25)
        canvas.cutOut([g.outerLips], stroke: g.mouthWidth * 0.08)
        return canvas.image(feather: g.faceWidth * 0.02)
    }

    /// 下眼睑下方的月牙区域，避开睫毛
    private static func underEyeMask(_ g: FaceGeometry, region: CGRect) -> CIImage? {
        guard let canvas = MaskCanvas(region: region) else { return nil }
        canvas.context.setFillColor(gray: 1, alpha: 1)
        for center in [g.leftEyeCenter, g.rightEyeCenter] {
            let w = g.eyeWidth
            let oval = CGRect(x: center.x - w * 0.6, y: center.y - w * 0.75, width: w * 1.2, height: w * 0.55)
            canvas.context.fillEllipse(in: canvas.rect(oval))
        }
        canvas.cutOut([g.leftEye, g.rightEye], stroke: g.eyeWidth * 0.3)
        return canvas.image(feather: g.eyeWidth * 0.15)
    }

    private static func polygonMask(_ polygons: [[CGPoint]], region: CGRect, feather: CGFloat) -> CIImage? {
        guard let canvas = MaskCanvas(region: region) else { return nil }
        canvas.context.setFillColor(gray: 1, alpha: 1)
        for polygon in polygons { canvas.fill(polygon) }
        return canvas.image(feather: feather)
    }

    /// 旧记录：人脸框内的椭圆挖掉五官
    private static func legacySkinMask(box: CGRect, features: [[CGPoint]], region: CGRect, extent: CGRect) -> CIImage? {
        guard let canvas = MaskCanvas(region: region) else { return nil }
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: extent.minX + p.x * extent.width, y: extent.minY + (1 - p.y) * extent.height) }
        let a = px(CGPoint(x: box.minX + box.width * 0.08, y: box.minY + box.height * 1.05))
        let b = px(CGPoint(x: box.maxX - box.width * 0.08, y: box.minY + box.height * 0.05))
        canvas.context.setFillColor(gray: 1, alpha: 1)
        canvas.context.fillEllipse(in: canvas.rect(CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)))
        let faceWidth = box.width * extent.width
        canvas.cutOut(features.map { $0.map(px) }, stroke: faceWidth * 0.04)
        return canvas.image(feather: faceWidth * 0.02)
    }

    /// 两颊（眼睛和嘴角之间）的平均颜色，作为这张脸的肤色参考
    private static func cheekColor(_ image: CIImage, geometry g: FaceGeometry) -> CIImage {
        let size = g.eyeWidth * 0.6
        let averages = [g.leftEyeCenter, g.rightEyeCenter].map { eye in
            let center = CGPoint(x: eye.x, y: (eye.y + g.mouthCenter.y) / 2)
            let rect = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            return image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: rect)]).clampedToExtent()
        }
        let sum = averages[0].applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: averages[1]])
        return scaled(sum, by: 0.5)
    }

    private static func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        foreground.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask,
        ])
    }

    private static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        a.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: b])
    }

    private static func scaled(_ mask: CIImage, by amount: Double) -> CIImage {
        let v = CGFloat(min(1, max(0, amount)))
        return mask.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: v, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: v, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: v, w: 0),
        ])
    }

    // MARK: - 内核
    // 用 Core Image Kernel Language 写，免去单独编译 Metal 库；macOS 15 起仍可用（已标记弃用）。

    /// YUCI：绿通道与蓝通道叠加，突出皮肤上的暗斑
    private static let gbOverlay = CIColorKernel(source: """
    kernel vec4 gbOverlay(__sample s) {
        float ba = 2.0 * s.b * s.g;
        return vec4(ba, ba, ba, s.a);
    }
    """)!

    /// YUCI：高反差保留
    private static let highPass = CIColorKernel(source: """
    kernel vec4 highPass(__sample s, __sample blurred) {
        return vec4(s.rgb - blurred.rgb + vec3(0.5), s.a);
    }
    """)!

    /// YUCI：三次强光拉开反差，再按 75~164 拉伸成蒙版
    private static let maskBoost = CIColorKernel(source: """
    kernel vec4 maskBoost(__sample s) {
        float c = s.b;
        for (int i = 0; i < 3; ++i) {
            c = c < 0.5 ? c * c * 2.0 : 1.0 - (1.0 - c) * (1.0 - c) * 2.0;
        }
        c = clamp((c - 75.0 / 255.0) * (255.0 / (164.0 - 75.0)), 0.0, 1.0);
        return vec4(vec3(c), 1.0);
    }
    """)!

    /// 按这张脸自己的肤色做相似度：色度接近、亮度不太暗（头发、眉毛、阴影排除）
    private static let skinKey = CIColorKernel(source: """
    kernel vec4 skinKey(__sample s, __sample ref) {
        float sum = max(s.r + s.g + s.b, 0.0001);
        float refSum = max(ref.r + ref.g + ref.b, 0.0001);
        vec2 chroma = vec2(s.r, s.g) / sum;
        vec2 refChroma = vec2(ref.r, ref.g) / refSum;
        float d = distance(chroma, refChroma);
        float hue = 1.0 - smoothstep(0.035, 0.09, d);
        float light = smoothstep(0.15, 0.4, sum / refSum);
        float k = hue * light;
        return vec4(k, k, k, 1.0);
    }
    """)!

    /// 黑眼圈：比两颊暗的地方按差距提亮，并把偏青紫的颜色拉向肤色
    private static let darkLift = CIColorKernel(source: """
    kernel vec4 darkLift(__sample s, __sample ref, float amount) {
        float lum = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
        float refLum = dot(ref.rgb, vec3(0.2126, 0.7152, 0.0722));
        float gain = clamp(refLum / max(lum, 0.0001), 1.0, 1.8);
        vec3 lifted = s.rgb * mix(1.0, gain, amount * 0.75);
        vec3 toned = ref.rgb * (dot(lifted, vec3(0.2126, 0.7152, 0.0722)) / max(refLum, 0.0001));
        return vec4(mix(lifted, toned, amount * 0.35), s.a);
    }
    """)!

    /// 牙齿：只处理接近无彩色的亮像素（嘴唇、牙龈饱和度高，不受影响），去黄并略提亮
    private static let teethWhiten = CIColorKernel(source: """
    kernel vec4 teethWhiten(__sample s, float amount) {
        float hi = max(max(s.r, s.g), s.b);
        float lo = min(min(s.r, s.g), s.b);
        float neutral = smoothstep(0.35, 0.65, lo / max(hi, 0.0001));
        float lum = dot(s.rgb, vec3(0.2126, 0.7152, 0.0722));
        vec3 white = mix(s.rgb, vec3(lum), 0.7) * 1.12;
        return vec4(mix(s.rgb, white, neutral * amount), s.a);
    }
    """)!

    /// 两只眼径向放大：越靠近中心放大越多，边缘平滑过渡到不变
    private static let eyeWarp = CIWarpKernel(source: """
    vec2 bulge(vec2 p, vec2 c, float r, float s) {
        vec2 d = p - c;
        float t = length(d) / r;
        if (t >= 1.0) return p;
        return c + d * (1.0 - s * (1.0 - smoothstep(0.0, 1.0, t)));
    }
    kernel vec2 eyeWarp(vec2 left, vec2 right, float radius, float strength) {
        vec2 p = destCoord();
        p = bulge(p, left, radius, strength);
        p = bulge(p, right, radius, strength);
        return p;
    }
    """)!

    /// 局部平移变形：每个控制点 xy 为位置，zw 为移动量，权重 (1 - (d/r)²)² 从中心平滑降到半径处为 0。
    /// 不用 Gustafsson 的原式：移动量远小于半径时它在圆内近乎整体平移，半径处出现断层（实拍验证脸颊撕裂）
    private static let slimWarp = CIWarpKernel(source: """
    vec2 push(vec2 p, vec4 c, float r) {
        vec2 d = p - c.xy;
        float t = dot(d, d) / (r * r);
        if (t >= 1.0) return p;
        float w = (1.0 - t) * (1.0 - t);
        return p - w * c.zw;
    }
    kernel vec2 slimWarp(vec4 a, vec4 b, vec4 c, vec4 d, vec4 e, vec4 f, float radius) {
        vec2 p = destCoord();
        p = push(p, a, radius);
        p = push(p, b, radius);
        p = push(p, c, radius);
        p = push(p, d, radius);
        p = push(p, e, radius);
        p = push(p, f, radius);
        return p;
    }
    """)!
}

/// 关键点换算到 Core Image 像素坐标（原点左下）
private struct FaceGeometry {
    let faceContour, leftEye, rightEye, leftEyebrow, rightEyebrow, outerLips, innerLips: [CGPoint]
    let leftEyeCenter, rightEyeCenter: CGPoint
    let faceWidth: CGFloat

    init(shape: FaceShape, box: CGRect, extent: CGRect) {
        func px(_ p: CGPoint) -> CGPoint { CGPoint(x: extent.minX + p.x * extent.width, y: extent.minY + (1 - p.y) * extent.height) }
        faceContour = shape.faceContour.map(px)
        leftEye = shape.leftEye.map(px)
        rightEye = shape.rightEye.map(px)
        leftEyebrow = shape.leftEyebrow.map(px)
        rightEyebrow = shape.rightEyebrow.map(px)
        outerLips = shape.outerLips.map(px)
        innerLips = shape.innerLips.map(px)
        // 瞳孔点偶尔落在眼角，用眼睛轮廓中心更稳
        leftEyeCenter = Self.centroid(leftEye)
        rightEyeCenter = Self.centroid(rightEye)
        let xs = faceContour.map(\.x)
        faceWidth = max((xs.max() ?? 0) - (xs.min() ?? 0), box.width * extent.width * 0.8)
    }

    var eyeWidth: CGFloat {
        let widths = [leftEye, rightEye].map { ($0.map(\.x).max() ?? 0) - ($0.map(\.x).min() ?? 0) }
        return max(2, widths.max() ?? 0)
    }
    var mouthWidth: CGFloat { max(2, (outerLips.map(\.x).max() ?? 0) - (outerLips.map(\.x).min() ?? 0)) }
    var mouthCenter: CGPoint { Self.centroid(outerLips) }
    var browTop: CGFloat { (leftEyebrow + rightEyebrow).map(\.y).max() ?? leftEyeCenter.y }
    var chin: CGPoint { faceContour.min { $0.y < $1.y } ?? mouthCenter }
    /// 两眼中点与嘴的中间，作为瘦脸时的脸中线参考
    var faceCenter: CGPoint {
        CGPoint(x: (leftEyeCenter.x + rightEyeCenter.x + mouthCenter.x * 2) / 4, y: (leftEyeCenter.y + rightEyeCenter.y) / 2)
    }

    static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        return CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count), y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
    }
}

/// 只在人脸附近按较低分辨率画蒙版，再放大羽化；群像里的小脸也有足够精度
private final class MaskCanvas {
    let region: CGRect
    let scale: CGFloat
    let context: CGContext

    init?(region: CGRect) {
        guard region.width >= 2, region.height >= 2 else { return nil }
        scale = min(1, 1024 / max(region.width, region.height))
        let width = Int(region.width * scale), height = Int(region.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        self.region = region
        self.context = context
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setLineJoin(.round)
    }

    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - region.minX) * scale, y: (p.y - region.minY) * scale) }

    func rect(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX - region.minX) * scale, y: (r.minY - region.minY) * scale, width: r.width * scale, height: r.height * scale)
    }

    func fill(_ polygon: [CGPoint]) {
        guard let first = polygon.first else { return }
        context.beginPath()
        context.move(to: point(first))
        for p in polygon.dropFirst() { context.addLine(to: point(p)) }
        context.closePath()
        context.fillPath()
    }

    /// 填黑并外扩描边，盖住睫毛、眉毛边缘和唇线
    func cutOut(_ polygons: [[CGPoint]], stroke: CGFloat) {
        context.setFillColor(gray: 0, alpha: 1)
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(max(1, stroke * scale))
        for polygon in polygons {
            guard let first = polygon.first else { continue }
            context.beginPath()
            context.move(to: point(first))
            for p in polygon.dropFirst() { context.addLine(to: point(p)) }
            context.closePath()
            context.drawPath(using: .fillStroke)
        }
        context.setFillColor(gray: 1, alpha: 1)
    }

    func image(feather: CGFloat) -> CIImage? {
        guard let cg = context.makeImage() else { return nil }
        return CIImage(cgImage: cg)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(0.5, feather * scale))
            .cropped(to: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY))
            // 处理范围以外一律为 0，蒙版之外保持原图
            .composited(over: CIImage(color: .black))
            .cropped(to: region)
    }
}
