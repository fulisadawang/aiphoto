import CoreGraphics
import Foundation

/// 让看图模型找出画面里的干扰物并给出位置，转成画笔笔触后走去杂物流程。
/// 区分"背景杂物"（去除）和"主体相关物品"（孩子手里的玩具等，只记录不去除）
struct DistractionLocator {
    let client: VisionChatClient

    struct Item: Equatable {
        let name: String
        let isBackground: Bool
        /// 归一化坐标，原点左上
        let box: CGRect
    }

    /// hints：AI 选片时已发现的干扰物名称，帮助模型聚焦；note：摄影师对本场的要求（如"保留地上的落叶"）
    func locate(imageURL: URL, hints: [String], note: String? = nil) async throws -> [Item] {
        guard let image = ImageLoader.image(at: imageURL, maxPixel: 1280),
              let jpeg = ImageLoader.jpegData(image, quality: 0.85)
        else { throw AnalyzerError.unreadable(imageURL) }

        var text = "请找出这张照片里的干扰物。"
        if !hints.isEmpty { text += "选片时已经注意到：\(hints.joined(separator: "、"))。" }
        if let note, !note.isEmpty {
            text += "摄影师对这一场的要求（按要求决定哪些去除、哪些保留，要求保留的一律归为 subject）：\(note)"
        }
        let content: [[String: Any]] = [
            ["type": "text", "text": text],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]],
            ["type": "text", "text": Self.outputInstruction],
        ]
        // 服务会把请求路由到不同模型，偶尔格式不对，重试一次
        do {
            return try Self.parse(try await client.json(system: Self.systemPrompt, content: content))
        } catch is LocateError {
            return try Self.parse(try await client.json(system: Self.systemPrompt, content: content))
        }
    }

    enum LocateError: LocalizedError {
        case badFormat(String)
        var errorDescription: String? {
            switch self {
            case .badFormat(let text): "定位干扰物时模型返回的格式无法识别：\(text.prefix(120))"
            }
        }
    }

    /// 构成场景的景物，即使模型列为背景杂物也不去除：提示词里已经要求不要列，实拍中模型仍会偶尔把"远处围栏"列进来
    /// 虚化的前景树叶、枝条多是有意的框景：视觉修图组会把它们列成杂物，框里还带着远处树梢，去掉会抹掉真实的树
    static let sceneryWords = ["围栏", "栅栏", "篱笆", "树木", "草地", "天空", "池塘", "建筑", "叶", "枝"]

    /// 宽容解析，框的格式见 box(in:)
    static func parse(_ data: Data) throws -> [Item] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else { throw LocateError.badFormat(String(decoding: data, as: UTF8.self)) }
        return items.compactMap { item -> Item? in
            guard let name = item["name"] as? String, let box = box(in: item) else { return nil }
            let isScenery = sceneryWords.contains { name.contains($0) }
            return Item(name: name, isBackground: (item["category"] as? String) != "subject" && !isScenery, box: box)
        }
    }

    /// 从模型输出的一项里读出包围框（0～1000 → 归一化，原点左上）。
    /// 数字可能写成字符串；有的模型用 box_2d = [ymin, xmin, ymax, xmax]
    static func box(in item: [String: Any]) -> CGRect? {
        func number(_ value: Any?) -> Double? {
            if let value = value as? Double { return value }
            if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespaces)) }
            return nil
        }
        var edges = ["left", "top", "right", "bottom"].map { number(item[$0]) }
        if edges.contains(where: { $0 == nil }), let box = item["box_2d"] as? [Any], box.count == 4 {
            let v = box.map(number)
            edges = [v[1], v[0], v[3], v[2]]
        }
        guard let l = edges[0], let t = edges[1], let r = edges[2], let b = edges[3] else { return nil }
        // 模型偶尔会把左右或上下写反，统一排序；面积为 0 的丢弃
        let x0 = min(l, r), x1 = max(l, r), y0 = min(t, b), y1 = max(t, b)
        guard x1 > x0, y1 > y0 else { return nil }
        let box = CGRect(x: x0 / 1000, y: y0 / 1000, width: (x1 - x0) / 1000, height: (y1 - y0) / 1000)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return box.isNull ? nil : box
    }

    /// 把框转成覆盖整个框的画笔笔触（横向逐行涂满），外扩一点盖住物体边缘
    static func strokes(covering box: CGRect, imageAspect: CGFloat) -> [BrushStroke] {
        let pad = 0.03
        let rect = box.insetBy(dx: -box.width * pad - 0.004, dy: -box.height * pad - 0.004)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        // 半径以画面宽度为单位；纵向的归一化长度要按宽高比换算
        let heightInWidthUnits = rect.height / imageAspect
        let radius = max(0.004, min(rect.width, heightInWidthUnits) / 2)
        let rowStep = radius * imageAspect * 1.2
        var strokes: [BrushStroke] = []
        var y = rect.minY + radius * imageAspect
        repeat {
            let row = min(y, rect.maxY - radius * imageAspect)
            let left = rect.minX + radius, right = max(left, rect.maxX - radius)
            strokes.append(BrushStroke(points: [CGPoint(x: left, y: row), CGPoint(x: right, y: row)], radius: radius))
            y += rowStep
        } while y - rowStep < rect.maxY - radius * imageAspect
        return strokes
    }

    static let systemPrompt = """
    你是亲子与家庭纪实摄影的后期助手，负责找出照片里适合后期去除的干扰物。

    干扰物分两类：
    - background（背景杂物，后期会去除）：婴儿推车、杂物、垃圾桶、插座电线、路人、手机、水瓶、塑料袋、施工标志等与画面主题无关、去掉后画面更干净的东西。
    - subject（主体相关物品，不去除）：孩子手里拿着的、身上穿戴的、和家人互动用到的东西，如玩具、娃娃、篮子、气球、帽子，以及画面里的任何人物（家人）和宠物。

    不要列出：画面主体人物本身、建筑、树木、天空、草地、栅栏等构成场景的景物；也不要列出很小、去不去都无所谓的东西。
    """

    static let outputInstruction = """
    只输出一个 JSON 对象，不要其他文字，格式：
    {"items":[{"name":"右下角婴儿车","category":"background","left":930,"top":720,"right":1000,"bottom":1000}]}
    name 用简短中文写清位置和物体；category 为 background 或 subject；\
    left/top/right/bottom 是物体包围框，用 0～1000 的整数表示相对整张照片宽高的位置（左上角为 0,0），框要完整包住物体。\
    没有干扰物时输出 {"items":[]}。
    """
}
