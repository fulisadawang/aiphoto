import CoreGraphics
import Foundation

/// 对话改图的一条消息，跟着照片保存在选片记录里
struct ChatMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable {
        case user, assistant
    }

    var id = UUID()
    let role: Role
    let text: String
    var date = Date()
    /// 执行失败的说明，界面上标红
    var isError = false
    /// 这一步实际做了什么，界面上显示成结果卡片；旧记录和普通回复没有
    var step: ChatStep?
}

/// 对话里的一步修改：用于结果卡片的说明和「撤销这步」
struct ChatStep: Codable, Equatable {
    /// 具体改动，如「曝光 +0.30 EV」「去掉：右侧路人」
    var changes: [String]
    /// 调色前的参数；没调色为 nil
    var editBefore: EditSettings?
    var changedEdit = false
    /// 交给后台去除 / 重画的数量，以及已完成、失败的数量
    var jobs = 0
    var finished = 0
    var failed = 0
    /// 后台完成后生成的修补块，撤销这步时一并去掉
    var patchIDs: [UUID] = []
    /// Magpie 实际用来理解这句话的模型；旧记录没有
    var model: String?
    var undone = false

    var pending: Int { max(0, jobs - finished - failed) }
}

/// 对话改图：把摄影师的一句话交给看图模型，换算成调色参数、要去掉的物体和要重画的区域
struct ChatEditor {
    let client: VisionChatClient

    struct Target: Equatable {
        let name: String
        /// 归一化坐标，原点左上
        let box: CGRect
        /// 重画时给图片模型的英文指令；去除物体时为 nil，用去杂物的默认提示词
        let prompt: String?
        /// 人像修饰：位置以本地检测到的人脸为准
        var isFace = false
    }

    struct Plan: Equatable {
        /// 回给摄影师的一句话
        let reply: String
        /// 只含要修改的字段，值为修改后的目标值
        let adjust: [String: Double]
        let remove: [Target]
        let redraw: [Target]
        /// Magpie 实际用来回答的模型
        var model: String? = nil
    }

    enum PlanError: LocalizedError {
        case badFormat(String)
        var errorDescription: String? {
            switch self {
            case .badFormat(let text): "模型返回的格式无法识别：\(text.prefix(120))"
            }
        }
    }

    /// 可调的参数和范围，与修图面板的滑块一致
    static let ranges: [String: ClosedRange<Double>] = [
        "exposure": -2...2,
        "temperature": 2500...11000,
        "tint": -60...60,
        "highlights": -1...0,
        "shadows": 0...1,
        "contrast": -1...1,
        "vibrance": -1...1,
        "skinSmoothing": 0...1,
    ]

    /// image：当前效果（已含去杂物和调色）的缩小图，让模型在现状上理解"再亮一点"这类说法
    /// note：这张照片初修时摄影师对本场的总体要求，没有为 nil
    func plan(image: CGImage, edit: EditSettings, history: [ChatMessage], instruction: String, note: String? = nil) async throws -> Plan {
        guard let jpeg = ImageLoader.jpegData(image, quality: 0.85) else { throw CleanupEngine.CleanupError.render }
        var text = "当前修图参数：\(Self.describe(edit))\n"
        if let note, !note.isEmpty { text += "摄影师对这一场的总体修图要求（作为背景参考，以这次说的话为准）：\(note)\n" }
        let recent = history.suffix(8)
        if !recent.isEmpty {
            text += "之前的对话：\n" + recent.map { ($0.role == .user ? "摄影师：" : "助手：") + $0.text }.joined(separator: "\n") + "\n"
        }
        text += "摄影师这次说：\(instruction)"
        let content: [[String: Any]] = [
            ["type": "text", "text": text],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]],
            ["type": "text", "text": Self.outputInstruction],
        ]
        // 模型偶尔格式不对或回复中途断掉（只剩半截 JSON），重试一次
        func attempt() async throws -> Plan {
            let result = try await client.response(system: Self.systemPrompt, content: content)
            var plan = try Self.parse(result.data)
            plan.model = result.model
            return plan
        }
        do {
            return try await attempt()
        } catch let error where error is PlanError || error is VisionChatClient.ClientError {
            return try await attempt()
        }
    }

    /// 结果卡片上的调色说明：只列有变化的参数，写变化量
    static func changes(from before: EditSettings, to after: EditSettings) -> [String] {
        var lines: [String] = []
        func add(_ name: String, _ a: Double, _ b: Double, _ format: String, scale: Double = 1) {
            let delta = (b - a) * scale
            if abs(delta) >= 0.005 * scale { lines.append(name + " " + String(format: format, delta)) }
        }
        add("曝光", before.exposure, after.exposure, "%+.2f EV")
        add("色温", before.temperature, after.temperature, "%+.0fK")
        add("色调", before.tint, after.tint, "%+.0f")
        add("高光", before.highlights, after.highlights, "%+.2f")
        add("阴影", before.shadows, after.shadows, "%+.2f")
        add("对比度", before.contrast, after.contrast, "%+.2f")
        add("自然饱和度", before.vibrance, after.vibrance, "%+.2f")
        add("磨皮", before.skinSmoothing, after.skinSmoothing, "%+.0f", scale: 100)
        return lines
    }

    static func describe(_ edit: EditSettings) -> String {
        String(
            format: "exposure=%.2f, temperature=%.0f, tint=%.0f, highlights=%.2f, shadows=%.2f, contrast=%.2f, vibrance=%.2f, skinSmoothing=%.2f",
            edit.exposure, edit.temperature, edit.tint, edit.highlights, edit.shadows, edit.contrast, edit.vibrance, edit.skinSmoothing
        )
    }

    static func parse(_ data: Data) throws -> Plan {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reply = json["reply"] as? String
        else { throw PlanError.badFormat(String(decoding: data, as: UTF8.self)) }

        var adjust: [String: Double] = [:]
        for (key, value) in json["adjust"] as? [String: Any] ?? [:] {
            guard let range = ranges[key] else { continue }
            let number = (value as? Double) ?? (value as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if let number { adjust[key] = min(range.upperBound, max(range.lowerBound, number)) }
        }
        func targets(_ key: String, needsPrompt: Bool) -> [Target] {
            (json[key] as? [[String: Any]] ?? []).compactMap { item in
                guard let name = item["name"] as? String, let box = DistractionLocator.box(in: item) else { return nil }
                let prompt = (item["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if needsPrompt, prompt?.isEmpty != false { return nil }
                return Target(name: name, box: box, prompt: needsPrompt ? prompt : nil, isFace: item["face"] as? Bool == true)
            }
        }
        return Plan(reply: reply, adjust: adjust, remove: targets("remove", needsPrompt: false), redraw: targets("redraw", needsPrompt: true))
    }

    // MARK: - 位置校正

    /// 看图模型被路由到不同模型时框的精度差别很大（实拍中出现过整体偏上约 8% 的框，把小狗旁边的木门去掉了）。
    /// 人像修饰对齐到本地检测的人脸；其他物体放大局部再确认一次
    func resolve(_ target: Target, in image: CGImage, faces: [CGRect]) async throws -> CGRect? {
        if target.isFace, let face = Self.nearestFace(to: target.box, faces: faces) {
            // 向外扩一些，包住脸颊和下巴
            return face.insetBy(dx: -face.width * 0.2, dy: -face.height * 0.2).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return try await refine(target, in: image)
    }

    static func nearestFace(to box: CGRect, faces: [CGRect]) -> CGRect? {
        faces.min { hypot($0.midX - box.midX, $0.midY - box.midY) < hypot($1.midX - box.midX, $1.midY - box.midY) }
    }

    /// 以模型给的框为中心裁出约 3 倍大的局部，让模型确认里面有没有目标并重新框；没有返回 nil
    func refine(_ target: Target, in image: CGImage) async throws -> CGRect? {
        let box = target.box
        let width = min(1, max(0.3, box.width * 3)), height = min(1, max(0.3, box.height * 3))
        let region = CGRect(
            x: min(max(0, box.midX - width / 2), 1 - width), y: min(max(0, box.midY - height / 2), 1 - height),
            width: width, height: height
        )
        let pixels = CGRect(
            x: region.minX * Double(image.width), y: region.minY * Double(image.height),
            width: region.width * Double(image.width), height: region.height * Double(image.height)
        ).integral
        guard let crop = image.cropping(to: pixels), let jpeg = ImageLoader.jpegData(crop, quality: 0.9) else {
            throw CleanupEngine.CleanupError.render
        }
        let content: [[String: Any]] = [
            ["type": "text", "text": "这是从一张照片里裁出来的局部。里面有没有「\(target.name)」？"],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]],
            ["type": "text", "text": Self.refineInstruction],
        ]
        let data = try await client.json(system: "你负责在照片局部里精确框出指定的物体。", content: content)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlanError.badFormat(String(decoding: data, as: UTF8.self))
        }
        guard json["found"] as? Bool == true, let local = DistractionLocator.box(in: json) else { return nil }
        return CGRect(
            x: region.minX + local.minX * region.width, y: region.minY + local.minY * region.height,
            width: local.width * region.width, height: local.height * region.height
        )
    }

    static let refineInstruction = """
    只输出一个 JSON 对象，不要其他文字。有的话：{"found":true,"left":120,"top":300,"right":480,"bottom":760}，\
    left/top/right/bottom 用 0～1000 的整数表示相对这张局部图宽高的位置（左上角为 0,0），框要完整包住它；\
    没有的话：{"found":false}。
    """

    /// 把模型给的目标值写进修图参数
    static func applying(_ adjust: [String: Double], to edit: EditSettings) -> EditSettings {
        var edit = edit
        for (key, value) in adjust {
            switch key {
            case "exposure": edit.exposure = value
            case "temperature": edit.temperature = value
            case "tint": edit.tint = value
            case "highlights": edit.highlights = value
            case "shadows": edit.shadows = value
            case "contrast": edit.contrast = value
            case "vibrance": edit.vibrance = value
            case "skinSmoothing": edit.skinSmoothing = value
            default: break
            }
        }
        return edit
    }

    /// 重画的局部图放大回原尺寸超过这个倍数就不执行：实拍验证中放大约 6 倍的天空重画明显变糊，2.7 倍的脸部尚可
    static let maxRedrawUpscale = 3.0

    /// 重画时包在模型指令外面的约束：只改蒙版区域，保持真实感和光线一致
    static func redrawPrompt(_ instruction: String) -> String {
        """
        Edit only the masked (transparent) area of this photo: \(instruction). \
        Keep it photorealistic and consistent with the surrounding lighting, color and perspective. \
        Do not add text. Keep everything outside the mask unchanged. \
        If the area contains a person's face, keep the same person, identity and expression; make only subtle, natural changes.
        """
    }

    static let systemPrompt = """
    你是亲子与家庭纪实摄影的后期助手。摄影师会对一张照片说一句话，你要把它变成具体的修改。可以做三类事：

    1. adjust：调整整张照片的修图参数，给出修改后的目标值（不是增量），只列要改的参数：
       - exposure 曝光 EV，-2～2；"亮一点"约 +0.3，"亮很多"约 +0.7
       - temperature 色温 K，2500～11000，6500 为不调整；数值越高画面越暖，"暖一点"约 +500
       - tint 色调，-60～60，负值偏绿、正值偏洋红
       - highlights 高光，-1～0，负值压暗高光（天空、白衣服过亮时用）
       - shadows 阴影，0～1，正值提亮暗部
       - contrast 对比度，-1～1
       - vibrance 自然饱和度，-1～1，"颜色浓一点"约 +0.2；儿童肤色不宜过饱和
       - skinSmoothing 皮肤柔化，0～1
       "再……一点"表示在当前参数上继续同方向调整。
    2. remove：去掉画面里的某个东西（路人、垃圾桶、电线、杂物等），给出物体包围框。
    3. redraw：让图片模型重画一小块区域，用于局部小改动和人像修饰（瘦脸、美白、去眼袋、去痘、去黑眼圈等）。\
    给出区域包围框和英文 prompt，prompt 具体描述这块要变成什么样，如 "make the sky a clear natural blue"、\
    "slightly slim the girl's cheeks, keep it natural"。人像修饰的框只框住要改的那张脸（或那部分）。

    原则：
    - 整体的明暗冷暖用 adjust，不要用 redraw。redraw 的框不能超过画面宽高的五分之一，范围再大重画后会明显变糊。
    - 天空、草地这类大面积的改色（"天空蓝一点""草地绿一点"）不要用 redraw，用 adjust 近似（如 vibrance、temperature、highlights），并在 reply 里说明只能整体调整。
    - 框要完整包住目标，但不要过大；人像修饰不要框到别人。
    - 摄影师没说要改的地方不要动；不确定指的是哪个物体时，不做修改，在 reply 里问清楚。
    - 不要去掉画面里的孩子和家人。
    - reply 用一两句简短中文说明你做了什么（如"已把曝光提高到 +0.30 EV，画面更亮"），去除和重画会在后台完成，说"正在去掉……"。
    """

    static let outputInstruction = """
    只输出一个 JSON 对象，不要其他文字，格式：
    {"reply":"已把曝光提高到 +0.30 EV，并在后台去掉右侧路人","adjust":{"exposure":0.3},\
    "remove":[{"name":"右侧路人","left":820,"top":300,"right":900,"bottom":620}],\
    "redraw":[{"name":"女孩的脸","prompt":"slightly slim the girl's cheeks, keep it natural","face":true,"left":400,"top":200,"right":520,"bottom":380}]}
    left/top/right/bottom 用 0～1000 的整数表示相对整张照片宽高的位置（左上角为 0,0）。人像修饰（脸部、眼周、皮肤）的 redraw 加 "face":true。\
    不需要的部分给空对象或空数组。
    """
}
