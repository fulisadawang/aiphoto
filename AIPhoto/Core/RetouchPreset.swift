import CoreGraphics
import Foundation

/// 修图预设：风格、磨皮和几项调色偏移，加一段给 AI 的描述。
/// 不含曝光和色温（用户确认）：明暗由自动调色按每张光线决定，冷暖由描述或风格决定。
/// 高光、阴影、色调、对比度、饱和度是叠加在自动调色结果上的偏移量
struct RetouchPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var styleID: UUID?
    var styleStrength = 1.0
    var skinSmoothing = 0.25
    var highlights = 0.0
    var shadows = 0.0
    var tint = 0.0
    var contrast = 0.0
    var vibrance = 0.0
    /// 给 AI 的描述：调色、去杂物、对话改图都会参考
    var note = ""

    /// 在自动调色结果上叠加预设
    func applied(to auto: EditSettings) -> EditSettings {
        var edit = auto
        edit.styleID = styleID
        edit.styleStrength = styleStrength
        edit.skinSmoothing = skinSmoothing
        edit.highlights = Self.clamp(auto.highlights + highlights, "highlights")
        edit.shadows = Self.clamp(auto.shadows + shadows, "shadows")
        edit.tint = Self.clamp(auto.tint + tint, "tint")
        edit.contrast = Self.clamp(auto.contrast + contrast, "contrast")
        edit.vibrance = Self.clamp(auto.vibrance + vibrance, "vibrance")
        return edit
    }

    /// 从一张修好的照片生成预设：记下它相对自动调色结果多调了多少，曝光和色温不取
    static func from(edit: EditSettings, auto: EditSettings, name: String, note: String) -> RetouchPreset {
        RetouchPreset(
            name: name, styleID: edit.styleID, styleStrength: edit.styleStrength, skinSmoothing: edit.skinSmoothing,
            highlights: edit.highlights - auto.highlights, shadows: edit.shadows - auto.shadows, tint: edit.tint - auto.tint,
            contrast: edit.contrast - auto.contrast, vibrance: edit.vibrance - auto.vibrance, note: note
        )
    }

    static func clamp(_ value: Double, _ key: String) -> Double {
        guard let range = ChatEditor.ranges[key] else { return value }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}

/// 预设全局保存，所有照片文件夹共用
enum RetouchPresetStore {
    static let defaultKey = "defaultRetouchPreset"

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIPhoto/presets.json")
    }

    static func load() throws -> [RetouchPreset] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([RetouchPreset].self, from: Data(contentsOf: fileURL))
    }

    static func save(_ presets: [RetouchPreset]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(presets).write(to: fileURL, options: .atomic)
    }

    static var defaultID: UUID? {
        get { UserDefaults.standard.string(forKey: defaultKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: defaultKey) }
    }
}

/// AI 对本场诉求的理解：一组整场统一的调色偏移，叠加在每张照片的自动调色和预设之上
struct LookAdjust: Equatable {
    /// 给摄影师看的一句话，如"偏暖通透：色温 +400K、对比 +0.10、饱和 +0.15"
    let summary: String
    let deltas: [String: Double]

    /// 偏移量的上限，避免一句描述把整场调过头
    static let limits: [String: Double] = [
        "exposure": 0.7, "temperature": 1500, "tint": 20, "highlights": 0.5,
        "shadows": 0.5, "contrast": 0.4, "vibrance": 0.4,
    ]

    func applied(to edit: EditSettings) -> EditSettings {
        var edit = edit
        for (key, delta) in deltas {
            switch key {
            case "exposure": edit.exposure = RetouchPreset.clamp(edit.exposure + delta, key)
            case "temperature": edit.temperature = RetouchPreset.clamp(edit.temperature + delta, key)
            case "tint": edit.tint = RetouchPreset.clamp(edit.tint + delta, key)
            case "highlights": edit.highlights = RetouchPreset.clamp(edit.highlights + delta, key)
            case "shadows": edit.shadows = RetouchPreset.clamp(edit.shadows + delta, key)
            case "contrast": edit.contrast = RetouchPreset.clamp(edit.contrast + delta, key)
            case "vibrance": edit.vibrance = RetouchPreset.clamp(edit.vibrance + delta, key)
            default: break
            }
        }
        return edit
    }
}

/// 把摄影师对本场的描述换算成整场统一的调色偏移。整场只理解一次，避免每张理解不同导致颜色不统一
struct LookInterpreter {
    let client: VisionChatClient

    enum InterpretError: LocalizedError {
        case badFormat(String)
        var errorDescription: String? {
            switch self {
            case .badFormat(let text): "理解本场诉求时模型返回的格式无法识别：\(text.prefix(120))"
            }
        }
    }

    /// samples：本场几张代表照片（已做自动调色和预设的缩小图），让模型在现状上判断要偏多少
    func interpret(note: String, samples: [CGImage]) async throws -> LookAdjust {
        var content: [[String: Any]] = [["type": "text", "text": "摄影师对这一场照片的修图要求：\(note)\n下面是本场的几张代表照片（已做基础调色）："]]
        for image in samples {
            guard let jpeg = ImageLoader.jpegData(image, quality: 0.8) else { continue }
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]])
        }
        content.append(["type": "text", "text": Self.outputInstruction])
        do {
            return try Self.parse(try await client.json(system: Self.systemPrompt, content: content))
        } catch let error where error is InterpretError || error is VisionChatClient.ClientError {
            return try Self.parse(try await client.json(system: Self.systemPrompt, content: content))
        }
    }

    static func parse(_ data: Data) throws -> LookAdjust {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = json["summary"] as? String
        else { throw InterpretError.badFormat(String(decoding: data, as: UTF8.self)) }
        var deltas: [String: Double] = [:]
        for (key, value) in json["adjust"] as? [String: Any] ?? [:] {
            guard let limit = LookAdjust.limits[key] else { continue }
            let number = (value as? Double) ?? (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if let number, number != 0 { deltas[key] = min(limit, max(-limit, number)) }
        }
        return LookAdjust(summary: summary, deltas: deltas)
    }

    static let systemPrompt = """
    你是亲子与家庭纪实摄影的后期助手。摄影师会描述这一场照片想要的整体效果，你要把它换算成一组对整场所有照片统一生效的调色偏移量（在每张照片已有参数上增减）：
    - exposure 曝光 EV，±0.7 以内；"人脸提亮一些"约 +0.2
    - temperature 色温 K，±1500 以内；正值更暖，"偏暖"约 +300～+500
    - tint 色调，±20 以内；负值偏绿、正值偏洋红，"肤色红润"可略加 +3～+6
    - highlights 高光，±0.5 以内；负值压暗高光
    - shadows 阴影，±0.5 以内；正值提亮暗部，"通透"常配合 +0.1
    - contrast 对比度，±0.4 以内
    - vibrance 自然饱和度，±0.4 以内；儿童肤色不宜过饱和

    原则：只换算描述里和颜色、明暗有关的部分；描述里关于去掉或保留物体的内容不用管。看代表照片的现状判断幅度，现状已经满足的就不要再加。没有提到的参数不要列出。
    """

    static let outputInstruction = """
    只输出一个 JSON 对象，不要其他文字，格式：
    {"summary":"偏暖通透：色温 +400K、阴影 +0.10、对比 +0.10、饱和 +0.15","adjust":{"temperature":400,"shadows":0.1,"contrast":0.1,"vibrance":0.15}}
    summary 用一句简短中文说明你的理解和具体调整；描述里没有颜色明暗要求时 adjust 给空对象。
    """
}

/// 套用预设和本场诉求后防止饱和颜色溢出：红墙、红衣服在偏暖加对比后容易整片到顶、丢失纹理
enum ClipGuard {
    /// 相对自动调色结果，新增溢出超过这个比例就降低本张的调整强度
    static let maxNewlyClipped = 0.03

    /// 任一通道 ≥ 250 的像素比例
    static func clippedFraction(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: PhotoRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew, width * height > 0 else { return 0 }
        var count = 0
        for index in stride(from: 0, to: bytes.count, by: 4) where max(bytes[index], bytes[index + 1], bytes[index + 2]) >= 250 {
            count += 1
        }
        return Double(count) / Double(width * height)
    }

    /// 在自动调色结果和目标之间按比例取值；风格和磨皮取目标
    static func blend(from auto: EditSettings, to target: EditSettings, _ t: Double) -> EditSettings {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        var edit = target
        edit.exposure = mix(auto.exposure, target.exposure)
        edit.temperature = mix(auto.temperature, target.temperature)
        edit.tint = mix(auto.tint, target.tint)
        edit.highlights = mix(auto.highlights, target.highlights)
        edit.shadows = mix(auto.shadows, target.shadows)
        edit.contrast = mix(auto.contrast, target.contrast)
        edit.vibrance = mix(auto.vibrance, target.vibrance)
        return edit
    }
}
