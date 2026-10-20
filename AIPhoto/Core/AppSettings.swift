import Foundation

/// 设置项统一放在 UserDefaults，设置页用 @AppStorage 读写同样的 key
enum AppSettings {
    static let modelKey = "selectModel"
    static let chatModelKey = "chatEditModel"
    static let baseURLKey = "selectBaseURL"
    static let keychainAccount = "select-api-key"
    static let perGroupKey = "aiCandidatesPerGroup"
    static let blurKey = "blurThreshold"
    static let gapKey = "burstMaxGap"
    static let distanceKey = "burstMaxDistance"

    static let usdToCnyKey = "usdToCny"
    /// 选的模型出错时自动换成推荐模型重试一次
    static let autoFallbackKey = "aiAutoFallback"
    static let defaultBaseURL = "http://127.0.0.1:3425/v1"

    static func registerDefaults() {
        // 旧版本在设置里存过 auto-auto 的，改回默认（Gemini 分组）
        if UserDefaults.standard.string(forKey: modelKey) == "group/auto-auto" {
            UserDefaults.standard.removeObject(forKey: modelKey)
        }
        UserDefaults.standard.register(defaults: [
            modelKey: ModelCatalog.recommended(for: .culling),
            usdToCnyKey: 7.2,
            autoFallbackKey: true,
            chatModelKey: ModelCatalog.recommended(for: .chat),
            baseURLKey: defaultBaseURL,
            perGroupKey: 6,
            blurKey: 40.0,
            gapKey: 3.0,
            distanceKey: 0.6,
        ])
    }

    /// 用量统计把 Magpie 的美元折算价换成人民币
    static var usdToCny: Double { UserDefaults.standard.double(forKey: usdToCnyKey) }
    static var baseURL: String { UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL }
    static var perGroup: Int { UserDefaults.standard.integer(forKey: perGroupKey) }
    static var autoFallback: Bool { UserDefaults.standard.bool(forKey: autoFallbackKey) }

    static var cullingParams: Culling.Params {
        let defaults = UserDefaults.standard
        return Culling.Params(
            maxGap: defaults.double(forKey: gapKey),
            maxDistance: Float(defaults.double(forKey: distanceKey)),
            blurThreshold: defaults.double(forKey: blurKey)
        )
    }
}
