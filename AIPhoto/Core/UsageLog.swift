import Foundation

/// AI 调用的用途，用量统计按它拆分
enum AIPurpose: String, Codable, CaseIterable {
    case culling, locate, cleanup, chat, chatRedraw, look, compositeBlend

    var title: String {
        switch self {
        case .culling: "AI 选片"
        case .locate: "找杂物"
        case .cleanup: "去杂物出图"
        case .chat: "对话改图"
        case .chatRedraw: "对话改图出图"
        case .look: "理解本场诉求"
        case .compositeBlend: "合成融合出图"
        }
    }
}

/// 本 App 发出的一次 AI 请求。费用以 Magpie 的记录为准，这里只记"哪场、做什么"，用来和 Magpie 对账
struct UsageEntry: Codable, Equatable {
    var start: Date
    var end: Date
    var purpose: AIPurpose
    /// 照片文件夹名，按场次汇总用
    var shoot: String?
    /// 对话类请求的返回 id，与 Magpie 记录的 response_id 一致；出图请求没有，按时间对账
    var responseID: String?
    var requestedModel: String
    var ok: Bool
}

/// 用量日志：一行一条 JSON，存在 Application Support/AIPhoto/usage.jsonl
final class UsageLog: @unchecked Sendable {
    static let shared = UsageLog()

    private let lock = NSLock()
    private var currentShoot: String?

    var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIPhoto/usage.jsonl")
    }

    /// 打开照片文件夹时设置，之后的请求都记到这一场
    func setShoot(_ name: String?) {
        lock.lock()
        currentShoot = name
        lock.unlock()
    }

    func record(purpose: AIPurpose, start: Date, responseID: String?, requestedModel: String, ok: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let entry = UsageEntry(
            start: start, end: Date(), purpose: purpose, shoot: currentShoot,
            responseID: responseID, requestedModel: requestedModel, ok: ok
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        // 记日志失败不影响 AI 功能本身，只会让统计少一条
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: fileURL)
        }
    }

    func entries(since: Date) -> [UsageEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(UsageEntry.self, from: Data($0)) }
            .filter { $0.start >= since }
    }
}

/// Magpie 网关的用量接口：按调用程序名筛出本 App 的请求，以及各订阅账号的额度
enum MagpieUsage {
    /// 请求头里的程序名，Magpie 按它区分调用方
    static let agent = "XiaoyuZhuanshu"

    static var userAgent: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        return "\(agent)/\(version)"
    }

    struct Row: Decodable {
        let t: String
        let model: String?
        let req: String?
        let `in`: Int?
        let out: Int?
        let cost: Double?
        let priced: Bool?
        let response_id: String?
        let status: Int?

        var date: Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.date(from: t) ?? ISO8601DateFormatter().date(from: t)
        }
    }

    struct Quota: Decodable {
        struct Window: Decodable {
            let name: String?
            let used: Double?
            let remaining: Double?
            let display: String?
        }
        let provider: String?
        let name: String?
        let kind: String?
        let plan: String?
        let windows: [Window]?
    }

    /// Magpie 根地址：设置里存的是 .../v1
    private static func root(_ baseURL: URL) -> URL {
        baseURL.lastPathComponent == "v1" ? baseURL.deletingLastPathComponent() : baseURL
    }

    /// 近 30 天本 App 的全部请求（分页取完）
    static func rows(baseURL: URL) async throws -> [Row] {
        struct Page: Decodable { let rows: [Row]; let total: Int? }
        var all: [Row] = []
        var offset = 0
        while true {
            var components = URLComponents(url: root(baseURL).appendingPathComponent("v1/magpie/usage/requests"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "agent", value: agent), URLQueryItem(name: "period", value: "30d"),
                URLQueryItem(name: "limit", value: "500"), URLQueryItem(name: "offset", value: String(offset)),
            ]
            let (data, _) = try await URLSession.shared.data(from: components.url!)
            let page = try JSONDecoder().decode(Page.self, from: data)
            all += page.rows
            offset += page.rows.count
            if page.rows.isEmpty || offset >= (page.total ?? 0) { return all }
        }
    }

    static func quotas(baseURL: URL) async throws -> [Quota] {
        struct List: Decodable { let data: [Quota] }
        let (data, _) = try await URLSession.shared.data(from: root(baseURL).appendingPathComponent("v1/magpie/quotas"))
        return try JSONDecoder().decode(List.self, from: data).data
    }
}

/// 本地日志与 Magpie 记录对账后的汇总
struct UsageReport {
    struct Line: Identifiable {
        let id: String
        var calls = 0
        var failures = 0
        var inputTokens = 0
        var outputTokens = 0
        /// 美元；未能计价的请求不计入
        var cost = 0.0
        var unpriced = 0
    }

    var byShoot: [Line] = []
    var byPurpose: [Line] = []
    var byModel: [Line] = []
    var total = Line(id: "合计")
    /// 实际用到 Claude 的次数（用户不用 Claude）
    var claudeCalls = 0

    /// 对话类按 response_id 对上；出图按时间窗口和请求的模型对上
    static func build(entries: [UsageEntry], rows: [Row]) -> UsageReport {
        var byID: [String: MagpieUsage.Row] = [:]
        var unmatched: [(Date, MagpieUsage.Row)] = []
        for row in rows {
            if let id = row.response_id { byID[id] = row } else if let date = row.date { unmatched.append((date, row)) }
        }
        var report = UsageReport()
        var shoots: [String: Line] = [:], purposes: [String: Line] = [:], models: [String: Line] = [:]
        for entry in entries {
            var row = entry.responseID.flatMap { byID[$0] }
            // Magpie 记的是请求开始时间；连续的出图请求首尾相接，取开始时间最接近的一条，避免前一条抢走后一条的记录
            let candidates = unmatched.indices.filter { index in
                let (date, candidate) = unmatched[index]
                // 出图请求不传模型时由 Magpie 选默认图片模型，按模型名里的 image 认
                let sameModel = entry.requestedModel.isEmpty
                    ? candidate.model?.contains("image") == true
                    : candidate.req == entry.requestedModel
                return sameModel && date >= entry.start.addingTimeInterval(-3) && date <= entry.end.addingTimeInterval(3)
            }
            if row == nil, let index = candidates.min(by: {
                abs(unmatched[$0].0.timeIntervalSince(entry.start)) < abs(unmatched[$1].0.timeIntervalSince(entry.start))
            }) {
                row = unmatched.remove(at: index).1
            }
            let model = row?.model ?? (entry.requestedModel.isEmpty ? "默认图片模型" : entry.requestedModel)
            func add(_ line: inout Line) {
                line.calls += 1
                if !entry.ok { line.failures += 1 }
                line.inputTokens += row?.in ?? 0
                line.outputTokens += row?.out ?? 0
                if let cost = row?.cost, row?.priced != false { line.cost += cost } else { line.unpriced += 1 }
            }
            add(&shoots[entry.shoot ?? "（未打开文件夹）", default: Line(id: entry.shoot ?? "（未打开文件夹）")])
            add(&purposes[entry.purpose.title, default: Line(id: entry.purpose.title)])
            add(&models[model, default: Line(id: model)])
            add(&report.total)
            if model.lowercased().contains("claude") { report.claudeCalls += 1 }
        }
        report.byShoot = shoots.values.sorted { $0.cost > $1.cost }
        report.byPurpose = purposes.values.sorted { $0.cost > $1.cost }
        report.byModel = models.values.sorted { $0.cost > $1.cost }
        return report
    }

    typealias Row = MagpieUsage.Row
}
