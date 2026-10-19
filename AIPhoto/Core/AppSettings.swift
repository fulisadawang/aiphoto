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

    static let defaultModel = "group/auto-auto"
    /// 对话改图要框出物体位置。实拍对比：auto-auto 路由到的模型 3 次都把小狗框到旁边的木门上，Gemini 3 次都框准
    static let defaultChatModel = "group/auto-gemini-3-8-flash"
    static let defaultBaseURL = "http://127.0.0.1:3425/v1"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            modelKey: defaultModel,
            chatModelKey: defaultChatModel,
            baseURLKey: defaultBaseURL,
            perGroupKey: 6,
            blurKey: 40.0,
            gapKey: 3.0,
            distanceKey: 0.6,
        ])
    }

    static var model: String { UserDefaults.standard.string(forKey: modelKey) ?? defaultModel }
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
