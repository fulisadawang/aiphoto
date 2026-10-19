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

    init(id: String) {
        self.id = id
    }

    /// 扫描时至少会填入其中一个文件；优先用相机直出 JPG，比解码 RAW 快得多
    var displayURL: URL { renderedURL ?? rawURL! }

    /// 修图、去杂物、导出都基于这个文件：有 RAW 用 RAW
    var editURL: URL { rawURL ?? renderedURL! }

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

struct Session: Codable {
    var version = 1
    var photos: [Photo]
    var groups: [PhotoGroup]
}
