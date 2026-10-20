import Foundation

/// App 里用到 AI 的五件事，每件事可以单独选模型
enum AIUse: String, CaseIterable, Identifiable {
    case culling, locate, chat, look, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .culling: "AI 选片"
        case .locate: "找杂物"
        case .chat: "对话改图"
        case .look: "理解修图描述"
        case .image: "画图"
        }
    }

    var detail: String {
        switch self {
        case .culling: "挑每组最好的照片，张数多，便宜快就好"
        case .locate: "框出路人、垃圾桶，框偏了会擦到孩子，要准"
        case .chat: "听懂你打的话，找到要改的地方"
        case .look: "把「通透一点、暖一点」换算成调色数值"
        case .image: "去杂物、重画、合成时把图画出来"
        }
    }

    var symbol: String {
        switch self {
        case .culling: "photo.badge.checkmark"
        case .locate: "viewfinder"
        case .chat: "bubble.left.and.text.bubble.right"
        case .look: "paintpalette"
        case .image: "paintbrush.pointed"
        }
    }

    /// 存设置的 key；选片、对话改图、画图沿用旧版本的 key，升级后设置不丢
    var key: String {
        switch self {
        case .culling: AppSettings.modelKey
        case .locate: "locateModel"
        case .chat: AppSettings.chatModelKey
        case .look: "lookModel"
        case .image: InpaintService.modelKey
        }
    }
}

/// 设置页里列出的候选模型。值为空字符串表示「跟随」：理解修图描述跟随 AI 选片，画图用服务默认的图片模型
struct ModelOption: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String
    var recommended = false
    var discouraged = false
}

enum ModelCatalog {
    /// 不用 auto-auto：实测会被路由到 Claude（用户明确不用 Claude），而且对话改图 3 次都把小狗框到木门上，Gemini 3 次都框准
    static let gemini = "group/auto-gemini-3-8-flash"

    /// 只有现在在用的模型实测过；其他候选按用户决定先不实测，标「未测试」（需求清单第 14 节）
    static func options(for use: AIUse) -> [ModelOption] {
        switch use {
        case .culling:
            [
                ModelOption(id: gemini, name: "Gemini 3.8 Flash", note: "推荐", recommended: true),
                ModelOption(id: "codex/gpt-5.6-luna", name: "GPT-5.6 Luna", note: "未测试"),
                ModelOption(id: "workbuddy/glm-5v-turbo", name: "GLM-5V Turbo", note: "未测试"),
            ]
        case .locate:
            [
                ModelOption(id: gemini, name: "Gemini 3.8 Flash", note: "推荐 · 定位准", recommended: true),
                ModelOption(id: "codex/gpt-6-luna", name: "GPT-6 Luna", note: "未测试"),
                // 实测会被路由到 Claude，而且框不准
                ModelOption(id: "group/auto-auto", name: "auto-auto", note: "不建议 · 框不准", discouraged: true),
            ]
        case .chat:
            [
                ModelOption(id: gemini, name: "Gemini 3.8 Flash", note: "推荐", recommended: true),
                ModelOption(id: "codex/gpt-6-luna", name: "GPT-6 Luna", note: "未测试"),
            ]
        case .look:
            [ModelOption(id: "", name: "同 AI 选片", note: "推荐", recommended: true)]
        case .image:
            // Magpie 不传模型时用 gpt-image-2；传 auto-auto 会被路由到只回文字的模型
            [ModelOption(id: "", name: "gpt-image-2", note: "推荐 · 服务默认", recommended: true)]
        }
    }

    static func recommended(for use: AIUse) -> String {
        options(for: use).first { $0.recommended }?.id ?? ""
    }

    static func stored(_ use: AIUse) -> String {
        (UserDefaults.standard.string(forKey: use.key) ?? recommended(for: use)).trimmingCharacters(in: .whitespaces)
    }

    /// 实际发给服务的模型名；画图为空表示不传 model
    static func model(for use: AIUse) -> String {
        let value = stored(use)
        if use == .look, value.isEmpty { return model(for: .culling) }
        return value
    }

    static var isAllRecommended: Bool {
        AIUse.allCases.allSatisfy { stored($0) == recommended(for: $0) }
    }

    static func resetToRecommended() {
        for use in AIUse.allCases { UserDefaults.standard.set(recommended(for: use), forKey: use.key) }
    }

    /// 出错时换用的模型：开关打开、且当前用的不是推荐模型时才有
    static func fallback(for use: AIUse, current: String) -> String? {
        let recommended = recommended(for: use == .look ? .culling : use)
        guard AppSettings.autoFallback, !recommended.isEmpty, recommended != current else { return nil }
        return recommended
    }

    static func displayName(_ id: String, use: AIUse) -> String {
        options(for: use).first { $0.id == id }?.name ?? id
    }

    static func registerDefaults() {
        let defaults = UserDefaults.standard
        // 旧版本找杂物和 AI 选片共用一个模型：升级时自己填过选片模型的，找杂物沿用它
        if defaults.object(forKey: AIUse.locate.key) == nil, let old = defaults.string(forKey: AppSettings.modelKey), !old.isEmpty {
            defaults.set(old, forKey: AIUse.locate.key)
        }
        defaults.register(defaults: [
            AIUse.locate.key: recommended(for: .locate),
            AIUse.look.key: recommended(for: .look),
        ])
    }
}

/// 设置页「再检查一次 / 测试连接」：请求 /models，返回服务上有多少个模型
enum ServiceProbe {
    enum ProbeError: LocalizedError {
        case invalidURL
        case http(Int)
        var errorDescription: String? {
            switch self {
            case .invalidURL: "地址填写有误"
            case .http(let status): "服务返回错误（\(status)）"
            }
        }
    }

    static func modelCount(baseURL text: String, apiKey: String) async throws -> Int {
        guard let baseURL = URL(string: text.trimmingCharacters(in: .whitespaces)), baseURL.scheme?.hasPrefix("http") == true
        else { throw ProbeError.invalidURL }
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 8
        request.setValue(MagpieUsage.userAgent, forHTTPHeaderField: "User-Agent")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ProbeError.http(status) }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["data"] as? [Any])?.count ?? 0
    }

    /// 连不上时给小白看的一句话
    static func hint(_ error: Error, baseURL: String) -> String {
        if baseURL.contains("127.0.0.1") || baseURL.contains("localhost"), error is URLError {
            return "本机的 Magpie 好像没打开。先启动 Magpie，再点「再检查一次」。"
        }
        return error.localizedDescription
    }
}
