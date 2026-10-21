import Foundation

/// 看图、画图请求共用：单个请求超过 3 分钟还没完成就放弃（用户 2026-10-21 要求），
/// 原来等 5 分钟，Magpie 组里换几次模型就像卡死
enum AIRequest {
    static let timeout: TimeInterval = 180

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        // 从发出到收完的总时长上限；只设 timeoutIntervalForRequest 时只要还在陆续收到数据就会一直等
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }()

    struct TimedOut: LocalizedError {
        var errorDescription: String? { "超过 3 分钟没有回应，已放弃" }
    }

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        request.timeoutInterval = timeout
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw TimedOut()
        }
    }

    /// 用户点了取消：不算失败，不提示错误
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// OpenAI 兼容的 /chat/completions 看图对话接口（如本机 Magpie）
struct VisionChatClient {
    var baseURL: URL
    var apiKey: String
    var model: String
    /// 用量统计里记到哪一项
    var purpose: AIPurpose

    enum ClientError: LocalizedError {
        case http(Int, String)
        case truncated
        case emptyResponse
        case invalidJSON(String)

        var errorDescription: String? {
            switch self {
            case let .http(status, message): "选片模型接口返回错误（\(status)）：\(message)"
            case .truncated: "模型的回复被截断，请减少每组送审张数后重试"
            case .emptyResponse: "模型没有返回内容"
            case .invalidJSON(let text): "模型没有按格式返回结果：\(text.prefix(200))"
            }
        }
    }

    /// content 为 OpenAI 格式的消息分段（text / image_url），返回模型输出的 JSON 数据
    /// 出错换模型由 Magpie 的路由组按顺序完成（需求清单第 18 节），这里不再自己重试
    func json(system: String, content: [[String: Any]]) async throws -> Data {
        try await response(system: system, content: content).data
    }

    /// 同时返回 Magpie 实际用的模型名（如 gpt-5.6-luna），对话改图卡片上显示
    func response(system: String, content: [[String: Any]]) async throws -> (data: Data, model: String?) {
        let start = Date()
        var responseID: String?
        var ok = false
        defer {
            UsageLog.shared.record(purpose: purpose, start: start, responseID: responseID, requestedModel: model, ok: ok)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Magpie 按程序名区分调用方，用量统计靠它筛出本 App 的请求
        request.setValue(MagpieUsage.userAgent, forHTTPHeaderField: "User-Agent")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": content],
            ],
            "response_format": ["type": "json_object"],
        ] as [String: Any])

        let (data, response) = try await AIRequest.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            // 错误响应不一定是 JSON，解析不了就原样展示
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw ClientError.http(status, message ?? String(decoding: data.prefix(500), as: UTF8.self))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first
        else { throw ClientError.emptyResponse }
        responseID = json["id"] as? String
        let actualModel = json["model"] as? String
        ok = true
        if choice["finish_reason"] as? String == "length" { throw ClientError.truncated }
        guard let text = (choice["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else {
            throw ClientError.emptyResponse
        }
        // 路由到的模型不一定严格遵守 json_object，可能包一层 ``` 代码块，取最外层花括号
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw ClientError.invalidJSON(text)
        }
        return (Data(text[start...end].utf8), actualModel)
    }
}
