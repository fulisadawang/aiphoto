import CoreImage
import Foundation

/// 非破坏性修图参数，只保存数值，预览和导出时才作用到图像上
struct EditSettings: Codable, Equatable {
    /// 曝光补偿（EV）
    var exposure = 0.0
    /// 拍摄时的光源色温（K）。6500 为不调整；数值越高画面越暖
    var temperature = 6500.0
    /// 色调偏移，负值偏绿、正值偏洋红
    var tint = 0.0
    /// 高光（-1~0，负值压暗高光）
    var highlights = 0.0
    /// 阴影（0~1，正值提亮暗部）
    var shadows = 0.0
    /// 对比度（-1~1）
    var contrast = 0.0
    /// 自然饱和度（-1~1），对肤色等已饱和颜色影响小，适合儿童肤色
    var vibrance = 0.0
    /// 皮肤柔化力度（0~1）
    var skinSmoothing = 0.0
    /// 个人风格预设
    var styleID: UUID?
    var styleStrength = 1.0

    static let neutral = EditSettings()

    init() {}

    /// 新增字段用 decodeIfPresent，兼容旧版本保存的参数
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 6500
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        skinSmoothing = try c.decodeIfPresent(Double.self, forKey: .skinSmoothing) ?? 0
        styleID = try c.decodeIfPresent(UUID.self, forKey: .styleID)
        styleStrength = try c.decodeIfPresent(Double.self, forKey: .styleStrength) ?? 1
    }

    /// 顺序：皮肤 → 个人风格（学自你的成片，含整体调色）→ 手动微调
    func apply(to image: CIImage, faces: [FaceInfo]) -> CIImage {
        var output = SkinRetoucher.apply(to: image, faces: faces, amount: skinSmoothing)
        if let styleID, let preset = StyleStore.shared.preset(styleID) {
            output = preset.apply(to: output, strength: styleStrength)
        }
        if temperature != 6500 || tint != 0 {
            output = output.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: temperature, y: tint),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        if exposure != 0 {
            output = output.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure])
        }
        if highlights != 0 || shadows != 0 {
            output = output.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + min(0, highlights),
                "inputShadowAmount": max(0, shadows),
            ])
        }
        if contrast != 0 {
            output = output.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1 + contrast * 0.5])
        }
        if vibrance != 0 {
            output = output.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: vibrance])
        }
        return output
    }
}
