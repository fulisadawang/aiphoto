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
    /// 用户定过选片不用 Claude：照样列出，选片时提醒
    var claude = false
    /// 实测调用不了（如 Cursor 免费版限制），照样列出，标原因
    var unavailable = false
}

enum ModelCatalog {
    /// Magpie 的「视觉修图」路由组：按 Magpie 里的顺序用模型，出错由 Magpie 换下一个。
    /// 实拍验证：31 张 AI 选片 18 秒全部完成、理由符合亲子纪实标准；找杂物的人、推车、桌子框得准，不碰孩子
    static let visionRetouch = "group/vision-retouch"
    /// 旧推荐，只用于把旧设置迁移到视觉修图组
    static let gemini = "group/auto-gemini-3-8-flash"

    /// 「视觉修图」组里的具体模型，顺序与 Magpie 里一致（用户 2026-10-21 要求全部列进下拉列表，需求清单第 18 节）。
    /// 2026-10-21 实测：两个 GPT 和 Gemini 能用；Grok 返回 Cursor 免费版不能用指定模型
    static let groupModels: [ModelOption] = [
        ModelOption(id: "codex/gpt-5.6-luna", name: "GPT-5.6-Luna", note: "Codex"),
        ModelOption(id: "codex/gpt-6-luna", name: "GPT-6-Luna", note: "Codex"),
        ModelOption(id: "antigravity/gemini-3.8-flash", name: "Gemini 3.8 Flash", note: "Antigravity"),
        ModelOption(id: "antigravity/claude-sonnet-4-6", name: "Claude Sonnet 4.6 (Thinking)", note: "Antigravity", claude: true),
        ModelOption(id: "cursor/grok-4.7@256k", name: "Grok 4.7 @ 256k", note: "Cursor 免费版目前用不了", unavailable: true),
        ModelOption(id: "cursor/grok-4.7@500k", name: "Grok 4.7 @ 500k", note: "Cursor 免费版目前用不了", unavailable: true),
        ModelOption(id: "cursor/claude-opus-5-5@300k", name: "Claude Opus 5.5 @ 300k", note: "Cursor", claude: true),
        ModelOption(id: "cursor/claude-opus-5-5@1m", name: "Claude Opus 5.5 @ 1m", note: "Cursor", claude: true),
        ModelOption(id: "cursor/claude-opus-5@300k", name: "Claude Opus 5 @ 300k", note: "Cursor", claude: true),
        ModelOption(id: "cursor/claude-opus-5@1m", name: "Claude Opus 5 @ 1m", note: "Cursor", claude: true),
        ModelOption(id: "antigravity/claude-opus-4-6-thinking", name: "Claude Opus 4.6 (Thinking)", note: "Antigravity", claude: true),
    ]

    static func options(for use: AIUse) -> [ModelOption] {
        switch use {
        case .culling, .locate, .chat:
            [ModelOption(id: visionRetouch, name: "视觉修图", note: "推荐 · Magpie 组，按顺序自动换", recommended: true)] + groupModels
        case .look:
            [ModelOption(id: "", name: "同 AI 选片", note: "推荐", recommended: true)] + groupModels
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

    /// 实际回答的模型名（Magpie 返回的 model，如 gpt-5.6-luna）是不是 Claude
    static func isClaude(_ model: String) -> Bool { model.lowercased().contains("claude") }

    static func displayName(_ id: String, use: AIUse) -> String {
        options(for: use).first { $0.id == id }?.name ?? id
    }

    static func registerDefaults() {
        let defaults = UserDefaults.standard
        // 推荐从 Gemini 改成视觉修图组（2026-10-20）：存着旧推荐值的改成新推荐，只迁移一次
        let migrationKey = "migratedToVisionRetouch"
        if !defaults.bool(forKey: migrationKey) {
            for use in [AIUse.culling, .locate, .chat] where defaults.string(forKey: use.key) == gemini {
                defaults.set(visionRetouch, forKey: use.key)
            }
            defaults.set(true, forKey: migrationKey)
        }
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
