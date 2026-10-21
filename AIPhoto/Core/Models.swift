import CoreGraphics
import Foundation

enum Decision: String, Codable {
    case none, pick, reject
}

enum PhotoFlag: String, Codable, CaseIterable {
    case blurry, eyesClosed, overexposed, underexposed

    var label: String {
        switch self {
        case .blurry: "模糊"
        case .eyesClosed: "闭眼"
        case .overexposed: "过曝"
        case .underexposed: "欠曝"
        }
    }
}

struct FaceInfo: Codable, Hashable {
    /// 归一化坐标，原点在左上角
    var box: CGRect
    /// Vision 人脸采集质量（0~1），适合在同一组连拍里横向比较
    var quality: Float?
    /// 眼睛张开程度：两眼中较大的"深色区域高度 / 眼宽"，越小越接近闭眼
    var eyeOpenness: Float?
    var isBlinking: Bool
    /// 需要保持清晰的五官轮廓（眼、眉、嘴），归一化坐标（原点左上）；旧记录没有该字段
    var features: [[CGPoint]]?
    /// 人像修复用的完整关键点；旧记录没有，打开人像工具时补测
    var shape: FaceShape?
}

/// Vision 人脸关键点，归一化坐标（原点左上）
struct FaceShape: Codable, Hashable {
    /// 从一侧太阳穴经下巴到另一侧，不含额头
    var faceContour: [CGPoint]
    var leftEye: [CGPoint]
    var rightEye: [CGPoint]
    var leftPupil: CGPoint
    var rightPupil: CGPoint
    var leftEyebrow: [CGPoint]
    var rightEyebrow: [CGPoint]
    var outerLips: [CGPoint]
    var innerLips: [CGPoint]
}

struct LocalAnalysis: Codable {
    /// 主体清晰度：有人脸取最大人脸区域，其次人体框，都没有时取最清晰的画面区块（拉普拉斯方差）
    var sharpness: Double
    var meanLuma: Double
    var highlightClip: Double
    var shadowClip: Double
    var faces: [FaceInfo]
    /// 没有可用人脸时（背影、侧脸被挡、远景）用人体检测框定的主体，归一化坐标（原点左上）
    var subject: CGRect?
    /// 16×16 区块清晰度（行优先，第 0 行在顶部），分组后按主体区域取值，不用重新解码图片
    var sharpnessGrid: [Float]?
    /// 归档后的 VNFeaturePrintObservation，用于连拍相似度分组
    var featurePrint: Data?

    var mainFace: FaceInfo? {
        faces.max { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
    }

    /// 放大检查时的焦点：优先最大人脸，其次人体
    var focusRect: CGRect? {
        mainFace?.box ?? subject
    }
}

struct AIVerdict: Codable {
    var score: Int
    var pick: Bool
    var reason: String
    var issues: [String]
    var distractions: [String]
}

struct Photo: Identifiable, Codable {
    /// 相对导入文件夹的路径（去掉扩展名），RAW 与 JPG 依此配对
    let id: String
    var rawURL: URL?
    var renderedURL: URL?
    var captureDate: Date?
    var analysis: LocalAnalysis?
    var ai: AIVerdict?
    var flags: Set<PhotoFlag> = []
    var localScore: Double = 0
    /// 组内比较用的主体清晰度（人脸 > 自身人体框 > 同组照片的人体框 > 最清晰区块）
    var subjectSharpness: Double?
    var decision: Decision = .none
    /// 用户亲手标记过就不再被自动预选覆盖
    var decidedByUser = false
    var rating = 0
    /// nil 表示没有调过色
    var edit: EditSettings?
    /// 去杂物的修补块，按顺序叠加；可选类型以兼容旧的选片记录
    var cleanups: [CleanupPatch]?
    /// 一键初修的记录；可选类型以兼容旧的选片记录
    var retouchLog: RetouchLog?
    /// 对话改图的记录；可选类型以兼容旧的选片记录
    var chat: [ChatMessage]?
    /// 初修时用的修图要求（预设描述加本场补充），去杂物和对话改图参考
    var retouchNote: String?

    init(id: String) {
        self.id = id
    }

    /// 扫描时至少会填入其中一个文件；优先用相机直出 JPG，比解码 RAW 快得多
    var displayURL: URL { renderedURL ?? rawURL! }

    /// 修图、去杂物、导出都基于这个文件：有相机 JPG 时用 JPG（保留相机厂商调校的色彩），只有 RAW 时才用 RAW 解码。
    /// 实拍对比：Apple 的 RAW 渲染红色更艳、对比更平，初修起点不如相机直出
    var editURL: URL { renderedURL ?? rawURL! }

    var fileName: String { (id as NSString).lastPathComponent }

    var formatLabel: String {
        switch (rawURL, renderedURL) {
        case let (raw?, rendered?): "\(raw.pathExtension.uppercased())+\(rendered.pathExtension.uppercased())"
        case let (raw?, nil): raw.pathExtension.uppercased()
        case let (nil, rendered?): rendered.pathExtension.uppercased()
        case (nil, nil): ""
        }
    }

    /// 导出到 XMP 的星级：淘汰为 -1（Lightroom 识别为"拒绝"），选用默认 3 星
    var exportRating: Int? {
        switch decision {
        case .pick: rating > 0 ? rating : 3
        case .reject: -1
        case .none: nil
        }
    }
}

/// 初修记录：自动做了什么、哪些需要摄影师看一眼
struct RetouchLog: Codable, Equatable {
    /// 已自动处理，如"曝光 +0.3""去掉了右下角婴儿车"
    var actions: [String] = []
    /// 建议检查，如消除区域较大、消除失败
    var warnings: [String] = []
    /// 初修无法修复的问题，如闭眼、模糊
    var unfixable: [String] = []
    /// 识别到但没有去除的主体相关物品，如孩子手里的玩具
    var kept: [String] = []

    /// 主体相关物品（草帽、篮子等）几乎每张亲子照都有，只记录、不算需要检查，否则总结里人人都"需要看一眼"
    var needsReview: Bool { !warnings.isEmpty || !unfixable.isEmpty }
}

/// 一次去杂物的结果：补好的局部图存成带透明通道的 PNG，按区域贴回原图
struct CleanupPatch: Codable, Identifiable, Equatable {
    let id: UUID
    /// 归一化区域（原点左上），相对于方向校正后的整张照片
    var rect: CGRect
}

/// 画笔笔迹，坐标归一化（原点左上），半径以画面宽度为单位
struct BrushStroke: Equatable {
    var points: [CGPoint]
    var radius: CGFloat
}

struct PhotoGroup: Identifiable, Codable, Hashable {
    let id: Int
    var photoIDs: [String]
}

/// 这批照片怎么处理，打开文件夹时选（需求清单第 17 节）
enum ShootMode: String, Codable, CaseIterable, Identifiable {
    /// AI 帮忙选片：打开后每组预选一张，AI 选完按 AI 推荐
    case ai
    /// 自己选片：不预选，只提示模糊、闭眼
    case manual
    /// 已在别处选好、调好色，只来修杂物和瑕疵：不分组、不选片、不自动修
    case editOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ai: "AI 选片"
        case .manual: "自己选片"
        case .editOnly: "已选好，只修图"
        }
    }

    var detail: String {
        switch self {
        case .ai: "AI 帮你挑每组最好的，可以一键初修（调色、磨皮、去杂物）"
        case .manual: "你自己挑，不替你预选；只提示模糊、闭眼。可以一键去杂物（不调色、不磨皮）"
        case .editOnly: "照片已经选好、调好色，只来去路人、垃圾、瑕疵。不分组，全部手动修，不会自动改颜色"
        }
    }

    var symbol: String {
        switch self {
        case .ai: "checkmark.rectangle.stack"
        case .manual: "hand.point.up.left"
        case .editOnly: "paintbrush.pointed"
        }
    }
}

struct Session: Codable {
    var version = 1
    var photos: [Photo]
    var groups: [PhotoGroup]
    /// 旧记录没有，按 AI 选片处理
    var mode: ShootMode?
}
