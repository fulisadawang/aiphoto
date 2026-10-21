import CoreGraphics
import Foundation
import ImageIO

/// 设置里可选的去杂物服务
enum InpaintService: String, CaseIterable, Identifiable {
    case none
    case openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "未配置"
        case .openAICompatible: "OpenAI 兼容接口（如 Magpie）"
        }
    }

    static let serviceKey = "inpaintService"
    static let baseURLKey = "inpaintBaseURL"
    static let modelKey = "inpaintModel"
    static let secretAccount = "inpaint-api-key"
    /// 画图是否单独设置连接；不单独设置时和看图的 AI 共用地址与密钥
    static let separateKey = "inpaintSeparate"

    static func registerDefaults() {
        let defaults = UserDefaults.standard
        // 旧版本单独填过、且和看图地址不同的，升级后保持「单独设置」
        if defaults.object(forKey: separateKey) == nil, let old = defaults.string(forKey: baseURLKey),
           old.trimmingCharacters(in: .whitespaces) != AppSettings.baseURL.trimmingCharacters(in: .whitespaces) {
            defaults.set(true, forKey: separateKey)
        }
        UserDefaults.standard.register(defaults: [
            separateKey: false,
            serviceKey: InpaintService.openAICompatible.rawValue,
            baseURLKey: "http://127.0.0.1:3425/v1",
            modelKey: "",
        ])
    }

    static var current: InpaintService {
        InpaintService(rawValue: UserDefaults.standard.string(forKey: serviceKey) ?? "") ?? .none
    }

    enum ConfigError: LocalizedError {
        case notConfigured
        case invalidBaseURL(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: "还没有配置去杂物服务，请在「小宇专属 › 设置…」里选择服务。"
            case .invalidBaseURL(let text): "去杂物服务地址无效：\(text)"
            }
        }
    }

    /// 按当前设置创建服务；未配置时抛错，由界面提示用户去设置
    static func makeProvider(purpose: AIPurpose) async throws -> InpaintProvider {
        switch current {
        case .none:
            throw ConfigError.notConfigured
        case .openAICompatible:
            let defaults = UserDefaults.standard
            let separate = defaults.bool(forKey: separateKey)
            let text = (separate ? defaults.string(forKey: baseURLKey) ?? "" : AppSettings.baseURL).trimmingCharacters(in: .whitespaces)
            guard let baseURL = URL(string: text), baseURL.scheme?.hasPrefix("http") == true else {
                throw ConfigError.invalidBaseURL(text)
            }
            let model = ModelCatalog.model(for: .image)
            return OpenAICompatibleInpainter(
                baseURL: baseURL,
                apiKey: try await SecretStore.loadIfSaved(account: separate ? secretAccount : AppSettings.secretAccount) ?? "",
                model: model.isEmpty ? nil : model,
                purpose: purpose
            )
        }
    }
}

/// 调用 OpenAI 兼容的 /images/edits 接口。这类模型通常会重画整张图，
/// 所以 CleanupEngine 只取蒙版内的结果贴回，区域外仍用原图像素
struct OpenAICompatibleInpainter: InpaintProvider {
    let baseURL: URL
    let apiKey: String
    /// nil 表示不传 model，由服务使用其默认图片模型
    let model: String?
    let purpose: AIPurpose

    static let prompt = """
    Remove whatever is inside the masked (transparent) area and fill it so it blends seamlessly with the surrounding scene: \
    continue the background texture, lighting and perspective. Do not add any new objects, people or text. \
    Keep everything outside the mask unchanged.
    """

    enum InpaintError: LocalizedError {
        case http(Int, String)
        case noImage
        case encode
        var errorDescription: String? {
            switch self {
            case let .http(status, message): "去杂物服务返回错误（\(status)）：\(message)"
            case .noImage: "去杂物服务没有返回图片"
            case .encode: "无法编码上传的图片"
            }
        }
    }

    func inpaint(image: CGImage, mask: CGImage, prompt: String?) async throws -> CGImage {
        let start = Date()
        var ok = false
        defer {
            UsageLog.shared.record(purpose: purpose, start: start, responseID: nil, requestedModel: model ?? "", ok: ok)
        }
        guard let imageData = CleanupEngine.pngData(image),
              let maskImage = Self.transparentMask(from: mask),
              let maskData = CleanupEngine.pngData(maskImage)
        else { throw InpaintError.encode }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        func file(_ name: String, _ data: Data) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(name).png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        if let model { field("model", model) }
        field("prompt", prompt ?? Self.prompt)
        file("image", imageData)
        file("mask", maskData)
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: baseURL.appendingPathComponent("images/edits"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(MagpieUsage.userAgent, forHTTPHeaderField: "User-Agent")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body

        let (data, response) = try await AIRequest.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // 错误响应不一定是 JSON，解析不了就原样展示
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard status == 200 else {
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw InpaintError.http(status, message ?? String(decoding: data.prefix(500), as: UTF8.self))
        }
        guard let first = (json?["data"] as? [[String: Any]])?.first else { throw InpaintError.noImage }

        let imageBytes: Data
        if let base64 = first["b64_json"] as? String, let decoded = Data(base64Encoded: base64) {
            imageBytes = decoded
        } else if let urlText = first["url"] as? String, let url = URL(string: urlText) {
            imageBytes = try await AIRequest.data(for: URLRequest(url: url)).0
        } else {
            throw InpaintError.noImage
        }
        guard let source = CGImageSourceCreateWithData(imageBytes as CFData, nil),
              let result = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw InpaintError.noImage }
        ok = true
        return result
    }

    /// OpenAI 约定蒙版 PNG 中透明的像素是要重绘的区域，与内部"白色=消除"相反
    static func transparentMask(from mask: CGImage) -> CGImage? {
        let width = mask.width, height = mask.height
        var gray = [UInt8](repeating: 0, count: width * height)
        let drew = gray.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.draw(mask, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for index in 0..<(width * height) {
            rgba[index * 4 + 3] = 255 - gray[index]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: PhotoRenderer.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
