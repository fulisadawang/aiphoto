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

    /// 不用 auto-auto：实测它会被路由到 Claude（claude-sonnet-4-6），用户明确不用 Claude 选片
    static let defaultModel = "group/auto-gemini-3-8-flash"
    static let usdToCnyKey = "usdToCny"
    /// 对话改图要框出物体位置。实拍对比：auto-auto 路由到的模型 3 次都把小狗框到旁边的木门上，Gemini 3 次都框准
    static let defaultChatModel = "group/auto-gemini-3-8-flash"
    static let defaultBaseURL = "http://127.0.0.1:3425/v1"

    static func registerDefaults() {
        // 旧版本在设置里存过 auto-auto 的，改回默认（Gemini 分组）
        if UserDefaults.standard.string(forKey: modelKey) == "group/auto-auto" {
            UserDefaults.standard.removeObject(forKey: modelKey)
        }
        UserDefaults.standard.register(defaults: [
            modelKey: defaultModel,
            usdToCnyKey: 7.2,
            chatModelKey: defaultChatModel,
            baseURLKey: defaultBaseURL,
            perGroupKey: 6,
            blurKey: 40.0,
            gapKey: 3.0,
            distanceKey: 0.6,
        ])
    }

    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? defaultModel }
    /// 用量统计把 Magpie 的美元折算价换成人民币
    static var usdToCny: Double { UserDefaults.standard.double(forKey: usdToCnyKey) }
    static var chatModel: String { UserDefaults.standard.string(forKey: chatModelKey) ?? defaultChatModel }
    static var baseURL: String { UserDefaults.standard.string(forKey: baseURLKey) ?? defaultBaseURL }
    static var perGroup: Int { UserDefaults.standard.integer(forKey: perGroupKey) }

    static var cullingParams: Culling.Params {
        let defaults = UserDefaults.standard
        return Culling.Params(
            maxGap: defaults.double(forKey: gapKey),
            maxDistance: Float(defaults.double(forKey: distanceKey)),
            blurThreshold: defaults.double(forKey: blurKey)
        )
    }
}
