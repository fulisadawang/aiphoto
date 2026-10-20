import Foundation

/// OpenAI 兼容的 /chat/completions 看图对话接口（如本机 Magpie）
struct VisionChatClient {
    var baseURL: URL
    var apiKey: String
    var model: String
    /// 用量统计里记到哪一项
    var purpose: AIPurpose
    /// 选的模型请求失败时换用的模型（推荐模型），nil 表示不重试
    var fallbackModel: String?

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
    func json(system: String, content: [[String: Any]]) async throws -> Data {
        do {
            return try await send(model: model, system: system, content: content, fallback: false)
        } catch {
            // 只在服务报错或连不上时换模型；回复格式不对、被截断属于内容问题，换模型不一定好，照常报错
            guard let fallbackModel, error is URLError || { if case .http = error as? ClientError { true } else { false } }()
            else { throw error }
            return try await send(model: fallbackModel, system: system, content: content, fallback: true)
        }
    }

    private func send(model: String, system: String, content: [[String: Any]], fallback: Bool) async throws -> Data {
        let start = Date()
        var responseID: String?
        var ok = false
        defer {
            UsageLog.shared.record(purpose: purpose, start: start, responseID: responseID, requestedModel: model, ok: ok, fallback: fallback)
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
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

        let (data, response) = try await URLSession.shared.data(for: request)
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
        ok = true
        if choice["finish_reason"] as? String == "length" { throw ClientError.truncated }
        guard let text = (choice["message"] as? [String: Any])?["content"] as? String, !text.isEmpty else {
            throw ClientError.emptyResponse
        }
        // 路由到的模型不一定严格遵守 json_object，可能包一层 ``` 代码块，取最外层花括号
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw ClientError.invalidJSON(text)
        }
        return Data(text[start...end].utf8)
    }
}
