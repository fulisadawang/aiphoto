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

/// 下拉列表里的一个模型。值为空字符串表示「跟随」：理解修图描述跟随 AI 选片，画图用服务默认的图片模型
struct ModelOption: Identifiable, Hashable {
    let id: String
    let name: String
    let note: String
    var recommended = false
    /// 用户定过选片不用 Claude：照样列出，选片时提醒
    var claude = false
}

/// 当前连接的服务（如 Magpie）实际有哪些模型：启动时和设置页检查连接时向 /models 取。
/// 下拉列表只列这些，不写死（用户 2026-10-22：别人的 Mac 连自己的 Magpie 时，列出来的还是作者那台的模型）
@MainActor @Observable
final class ServiceModels {
    static let shared = ServiceModels()

    /// 看图连接上的模型；nil 表示还没取到或取失败
    private(set) var ids: [String]?
    /// 画图单独设置连接时，那个连接上的模型
    private(set) var imageIDs: [String]?

    func set(_ ids: [String]?, image: Bool = false) {
        if image { imageIDs = ids } else { self.ids = ids }
    }

    /// 按设置里保存的地址和密钥重新取一次；取不到时清空，下拉列表只剩当前选中的
    func refresh() async {
        let defaults = UserDefaults.standard
        let baseURL = defaults.string(forKey: AppSettings.baseURLKey) ?? AppSettings.defaultBaseURL
        let key = (try? await SecretStore.loadIfSaved(account: AppSettings.secretAccount)) ?? ""
        ids = try? await ServiceProbe.models(baseURL: baseURL, apiKey: key)
        if defaults.bool(forKey: InpaintService.separateKey) {
            let imageURL = defaults.string(forKey: InpaintService.baseURLKey) ?? AppSettings.defaultBaseURL
            let imageKey = (try? await SecretStore.loadIfSaved(account: InpaintService.secretAccount)) ?? ""
            imageIDs = try? await ServiceProbe.models(baseURL: imageURL, apiKey: imageKey)
        }
    }

    /// 某件事的下拉列表用哪个连接上的模型
    func available(for use: AIUse) -> [String]? {
        use == .image && UserDefaults.standard.bool(forKey: InpaintService.separateKey) ? imageIDs : ids
    }
}

enum ModelCatalog {
    /// Magpie 的「视觉修图」路由组：按 Magpie 里的顺序用模型，出错由 Magpie 换下一个。
    /// 实拍验证：31 张 AI 选片 18 秒全部完成、理由符合亲子纪实标准；找杂物的人、推车、桌子框得准，不碰孩子
    static let visionRetouch = "group/vision-retouch"
    /// 旧推荐，只用于把旧设置迁移到视觉修图组
    static let gemini = "group/auto-gemini-3-8-flash"

    /// 下拉列表 = 当前连接的服务返回的模型：路由组在前（「视觉修图」组最前、标推荐），其余按服务返回的顺序
    @MainActor
    static func options(for use: AIUse) -> [ModelOption] {
        let ids = ServiceModels.shared.available(for: use) ?? []
        let groups = ids.filter { $0.hasPrefix("group/") }.sorted { $0 == visionRetouch && $1 != visionRetouch }
        let images = ids.filter(isImageModel)
        let models = ids.filter { !$0.hasPrefix("group/") && !isImageModel($0) }
        switch use {
        case .culling, .locate, .chat:
            return (groups + models).map(option)
        case .look:
            return [ModelOption(id: "", name: "同 AI 选片", note: "推荐", recommended: true)] + (groups + models).map(option)
        case .image:
            // Magpie 不传模型时用默认的图片模型；传 auto-auto 这类组会被路由到只回文字的模型
            return [ModelOption(id: "", name: "服务默认的画图模型", note: "推荐", recommended: true)] + images.map(option)
        }
    }

    private static func option(_ id: String) -> ModelOption {
        if id == visionRetouch {
            return ModelOption(id: id, name: "视觉修图", note: "推荐 · Magpie 组，按顺序自动换", recommended: true)
        }
        if id.hasPrefix("group/") {
            return ModelOption(id: id, name: "组：\(id.dropFirst("group/".count))", note: "Magpie 组")
        }
        // 「codex/gpt-5.6-luna」显示成「gpt-5.6-luna · codex」
        let parts = id.split(separator: "/", maxSplits: 1)
        let name = parts.count == 2 ? String(parts[1]) : id
        let note = parts.count == 2 ? String(parts[0]) : "模型"
        return ModelOption(id: id, name: name, note: note, claude: isClaude(id))
    }

    /// 只认名字里带 image 的为画图模型（如 gpt-image-2）；认不出的可以在「自定义…」里填
    private static func isImageModel(_ id: String) -> Bool { id.lowercased().contains("image") }

    static func recommended(for use: AIUse) -> String {
        switch use {
        case .culling, .locate, .chat: visionRetouch
        case .look, .image: ""
        }
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

    @MainActor
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

    /// 服务上所有模型的 id，按服务返回的顺序
    static func models(baseURL text: String, apiKey: String) async throws -> [String] {
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
        return (json?["data"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
    }

    /// 连不上时给小白看的一句话
    static func hint(_ error: Error, baseURL: String) -> String {
        if baseURL.contains("127.0.0.1") || baseURL.contains("localhost"), error is URLError {
            return "这台电脑上连不上 Magpie。127.0.0.1 指这台电脑自己：Magpie 装在这台上就先把它打开；装在另一台电脑上，要填那台电脑的地址（如 http://100.x.x.x:3425/v1）和 Magpie 的密钥。"
        }
        if case ProbeError.http(let status) = error, status == 401 || status == 403 {
            return "服务要求密钥（\(status)）。从别的电脑连 Magpie 时要在下面填 Magpie 的密钥。"
        }
        if error is URLError {
            return "连不上 \(baseURL)：确认那台电脑开着、Magpie 在运行，两台电脑网络互通（如都连着 Tailscale）。"
        }
        // 开着 Clash 这类代理时，连不上的地址由代理回 502/504（实测：100.x 地址不在代理例外里）
        if case ProbeError.http(let status) = error, [502, 503, 504].contains(status) {
            return "连不上 \(baseURL)（\(status)）：多半是代理软件挡住了，把这个地址加进代理的「不走代理」名单；也确认那台电脑开着、Magpie 在运行。"
        }
        return error.localizedDescription
    }
}
