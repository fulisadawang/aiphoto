import Foundation
import Vision

enum Culling {
    struct Params {
        /// 相邻两张拍摄间隔超过该秒数就不算同一组连拍
        var maxGap: TimeInterval
        /// 画面特征距离阈值，越小分组越严格
        var maxDistance: Float
        /// 主体清晰度绝对阈值，低于即标记模糊
        var blurThreshold: Double
    }

    /// 按拍摄时间排序后，把时间相近且画面相似的相邻照片归为一组
    static func group(_ photos: [Photo], params: Params) throws -> [PhotoGroup] {
        let sorted = photos.sorted {
            ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id)
        }
        var prints: [String: VNFeaturePrintObservation] = [:]
        for photo in sorted {
            guard let data = photo.analysis?.featurePrint else { continue }
            prints[photo.id] = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
        }

        var groups: [PhotoGroup] = []
        var current: [String] = []
        var previous: Photo?
        for photo in sorted {
            if let previous, try isSameBurst(previous, photo, prints: prints, params: params) {
                current.append(photo.id)
            } else {
                if !current.isEmpty { groups.append(PhotoGroup(id: groups.count + 1, photoIDs: current)) }
                current = [photo.id]
            }
            previous = photo
        }
        if !current.isEmpty { groups.append(PhotoGroup(id: groups.count + 1, photoIDs: current)) }
        return groups
    }

    /// 画面几乎一样时放宽的时间窗口：摄影师架好机位等孩子动作，同一场景常常前后拍十几秒
    static let sameSceneDistance: Float = 0.3
    static let sameSceneMaxGap: TimeInterval = 30

    private static func isSameBurst(
        _ a: Photo, _ b: Photo, prints: [String: VNFeaturePrintObservation], params: Params
    ) throws -> Bool {
        var gap: TimeInterval?
        if let dateA = a.captureDate, let dateB = b.captureDate {
            gap = dateB.timeIntervalSince(dateA)
            // 1 秒内的连拍必然是同一场景；孩子动作快、虚焦帧的画面特征会突变，不能再按相似度拆开
            if let gap, gap <= 1 { return true }
        }
        guard let printA = prints[a.id], let printB = prints[b.id] else {
            // 没有画面特征时只能靠时间判断
            return gap.map { $0 <= params.maxGap } ?? false
        }
        var distance: Float = 0
        try printA.computeDistance(&distance, to: printB)
        guard let gap else { return distance <= params.maxDistance }
        if distance <= sameSceneDistance { return gap <= sameSceneMaxGap }
        return gap <= params.maxGap && distance <= params.maxDistance
    }

    /// 计算问题标记和本地评分。清晰度在组内相对比较，避免不同场景光线差异导致误判
    static func score(_ photos: inout [String: Photo], groups: [PhotoGroup], blurThreshold: Double) {
        for group in groups {
            let members = group.photoIDs.compactMap { photos[$0] }
            // 连拍时主体位置基本不变：认不出人体的照片借用同组里认出来的那个区域，保证组内用同一标准比较
            let groupSubject = members.compactMap { $0.analysis?.subject }.first
            let sharpnessByID = Dictionary(uniqueKeysWithValues: members.compactMap { photo in
                photo.analysis.map { (photo.id, subjectSharpness($0, fallbackRegion: groupSubject)) }
            })
            let maxSharpness = sharpnessByID.values.max() ?? 0
            for var photo in members {
                guard let analysis = photo.analysis, let sharpness = sharpnessByID[photo.id] else { continue }
                photo.subjectSharpness = sharpness
                let relative = maxSharpness > 0 ? sharpness / maxSharpness : 0

                var flags = Set<PhotoFlag>()
                // 绝对阈值只对人脸区域可靠（人体框里常混着大片衣物、背景）；天空、墙面等少纹理画面的清晰度天然很低，只做组内相对比较
                let belowAbsolute = !analysis.faces.isEmpty && analysis.sharpness < blurThreshold
                if belowAbsolute || (members.count > 1 && relative < 0.35) {
                    flags.insert(.blurry)
                }
                if analysis.faces.contains(where: \.isBlinking) { flags.insert(.eyesClosed) }
                // 门槛定在 20%：顺光下的白窗框、白衣服常占 5～12%，主体曝光正常时不该整张标"过曝"；局部用过曝提示看
                if analysis.highlightClip > 0.2 { flags.insert(.overexposed) }
                if analysis.meanLuma < 0.15 && analysis.shadowClip > 0.3 { flags.insert(.underexposed) }

                let qualities = analysis.faces.compactMap(\.quality).map(Double.init)
                let faceQuality = qualities.isEmpty ? 0.5 : qualities.reduce(0, +) / Double(qualities.count)
                let exposure = 1 - min(1, (analysis.highlightClip + analysis.shadowClip) * 3)
                var score = 50 * relative + 35 * faceQuality + 15 * exposure
                if flags.contains(.blurry) { score -= 25 }
                if flags.contains(.eyesClosed) { score -= 20 }

                photo.flags = flags
                photo.localScore = max(0, score)
                photos[photo.id] = photo
            }
        }
    }

    /// 人脸 > 自身人体框 > 同组人体框（取区域内区块清晰度的最大值，人体框里常混有虚化背景）> 最清晰区块
    static func subjectSharpness(_ analysis: LocalAnalysis, fallbackRegion: CGRect?) -> Double {
        guard analysis.faces.isEmpty, let region = analysis.subject ?? fallbackRegion,
              let grid = analysis.sharpnessGrid
        else { return analysis.sharpness }
        let n = LocalAnalyzer.gridSize
        var best: Float = 0
        for gy in 0..<n {
            for gx in 0..<n {
                let center = CGPoint(x: (Double(gx) + 0.5) / Double(n), y: (Double(gy) + 0.5) / Double(n))
                if region.contains(center) { best = max(best, grid[gy * n + gx]) }
            }
        }
        // 区域比一个区块还小时取中心所在区块
        if best == 0 {
            let gx = min(n - 1, Int(region.midX * Double(n))), gy = min(n - 1, Int(region.midY * Double(n)))
            best = grid[gy * n + gx]
        }
        return Double(best)
    }

    static func ranked(_ group: PhotoGroup, in photos: [String: Photo]) -> [Photo] {
        group.photoIDs.compactMap { photos[$0] }.sorted { $0.localScore > $1.localScore }
    }
}
