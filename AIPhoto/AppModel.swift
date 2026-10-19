import AppKit
import Foundation
import Observation

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor @Observable
final class AppModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "全部"
        case unconfirmed = "未确认"
        case picked = "已选"
        case problems = "有问题"
        var id: String { rawValue }
    }

    var folderURL: URL?
    var photos: [String: Photo] = [:]
    var groups: [PhotoGroup] = []
    var selectedGroupID: Int?
    var selectedPhotoID: String?
    var filter: Filter = .all
    /// 放大状态全局共享，切换照片时保持倍数和位置，便于在连拍中逐张比较同一处
    var zoom = ZoomState()
    var showFaces = false
    /// 修复前后对比：大图中间一条分割线，左边原图、右边修复后；切换照片时保持
    var compareMode = false
    /// 分割线位置，占大图宽度的比例
    var compareDivider: CGFloat = 0.5

    /// 看片辅助开关，默认关闭，免得干扰看图
    var showPeaking = false
    var showClipping = false

    /// 网格总览：一屏看完整场照片，可多选批量操作
    var gridMode = false
    var gridSelection: Set<String> = []
    var gridThumbSize: CGFloat = 150

    /// 当前大图（修复后）的直方图，由大图视图在图像变化时计算
    var histogram: Histogram?

    /// 画笔模式：在大图上涂抹要去掉的物体
    var brushMode = false
    var strokes: [BrushStroke] = []
    /// 画笔半径，以画面宽度为单位
    var brushSize: CGFloat = 0.03

    var isBusy = false
    var progress: Double = 0
    var statusText = ""
    var alert: AlertInfo?

    private var saveTask: Task<Void, Never>?

    /// 撤销记录只保存某一类用户字段的旧值，并按字段恢复：
    /// AI 结果、后台去杂物等是异步写入的，整份回退会把它们一起冲掉
    private enum UndoKind {
        case decision, edit, cleanups
    }

    private struct UndoEntry {
        let kind: UndoKind
        let label: String
        let before: [String: Photo]
    }

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []

    /// 后台去杂物队列：不占住界面，摄影师可以继续选片
    struct CleanupJob: Identifiable {
        let id = UUID()
        let photoID: String
        let strokes: [BrushStroke]
        /// 要写进初修记录的物体名称，如"右下角婴儿车"；手动涂抹为 nil
        let itemName: String?
        /// 消除区域较大时完成后提示检查
        let isLarge: Bool
        var isRunning = false
    }

    var cleanupJobs: [CleanupJob] = []
    /// 正在让 AI 识别干扰物位置的照片
    var locatingPhotoIDs: Set<String> = []
    /// 一键初修进度：已处理 / 总数；nil 表示没有在初修
    var retouchProgress: (done: Int, total: Int)?
    var showRetouchSummary = false
    var showRetouchStart = false
    /// 本轮队列里失败的任务，队列清空时统一提示
    private var cleanupFailures: [String] = []
    /// 同时向去杂物服务发出的请求数
    private static let cleanupConcurrency = 2

        /// 个人风格预设列表（全局，与照片文件夹无关）
    var styles: [StylePreset] = []

    init() {
        do {
            styles = try StyleStore.shared.all()
        } catch {
            alert = AlertInfo(title: "读取风格预设失败", message: error.localizedDescription)
        }
    }

    // MARK: - 派生状态

    var visibleGroups: [PhotoGroup] {
        switch filter {
        case .all: groups
        case .unconfirmed: groups.filter { !members(of: $0).contains(where: \.decidedByUser) }
        case .picked: groups.filter { members(of: $0).contains { $0.decision == .pick } }
        case .problems: groups.filter { members(of: $0).contains { !$0.flags.isEmpty } }
        }
    }

    var selectedGroup: PhotoGroup? { groups.first { $0.id == selectedGroupID } }
    var selectedPhotos: [Photo] { selectedGroup.map(members(of:)) ?? [] }
    var selectedPhoto: Photo? { selectedPhotoID.flatMap { photos[$0] } }

    var undoLabel: String? {
        if brushMode, !strokes.isEmpty { return "画笔笔触" }
        return undoStack.last?.label
    }

    var redoLabel: String? { redoStack.last?.label }

    var pickedCount: Int { photos.values.filter { $0.decision == .pick }.count }
    var rejectedCount: Int { photos.values.filter { $0.decision == .reject }.count }
    var aiReviewedGroupCount: Int { groups.filter { members(of: $0).contains { $0.ai != nil } }.count }

    func members(of group: PhotoGroup) -> [Photo] {
        group.photoIDs.compactMap { photos[$0] }
    }

    /// 组的封面：已选的优先，其次 AI 分最高，再次本地分最高
    func representative(of group: PhotoGroup) -> Photo? {
        let list = members(of: group)
        return list.first { $0.decision == .pick }
            ?? list.filter { $0.ai != nil }.max { ($0.ai?.score ?? 0) < ($1.ai?.score ?? 0) }
            ?? list.max { $0.localScore < $1.localScore }
    }

    // MARK: - 打开与分析

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "打开"
        panel.message = "选择一场拍摄的照片文件夹（支持 RAW + JPG）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ folder: URL) {
        guard !isBusy else { return }
        folderURL = folder
        photos = [:]
        groups = []
        selectedGroupID = nil
        selectedPhotoID = nil
        undoStack = []
        redoStack = []
        cleanupJobs = []
        cleanupFailures = []
        locatingPhotoIDs = []
        retouchProgress = nil
        perform("正在扫描文件夹…") {
            let scanned = await Task.detached { PhotoScanner.scan(folder: folder) }.value
            guard !scanned.isEmpty else {
                self.alert = AlertInfo(title: "没有找到照片", message: "这个文件夹里没有 RAW 或 JPG 照片。")
                return
            }

            var saved: Session?
            do {
                saved = try SessionStore.load(folder: folder)
            } catch {
                self.alert = AlertInfo(title: "旧的选片记录无法读取", message: "将重新分析这个文件夹。\n\(error.localizedDescription)")
            }
            let savedPhotos = Dictionary(uniqueKeysWithValues: (saved?.photos ?? []).map { ($0.id, $0) })

            var merged: [String: Photo] = [:]
            for photo in scanned {
                // 沿用上次的分析和选片结果，文件路径以本次扫描为准
                var entry = savedPhotos[photo.id] ?? photo
                entry.rawURL = photo.rawURL
                entry.renderedURL = photo.renderedURL
                merged[photo.id] = entry
            }
            self.photos = merged
            try self.removeUnusedPatches(folder: folder)

            let savedGroups = saved?.groups ?? []
            let savedIDs = Set(savedGroups.flatMap(\.photoIDs))
            if !savedGroups.isEmpty, savedIDs == Set(merged.keys), merged.values.allSatisfy({ $0.analysis != nil }) {
                self.groups = savedGroups
                self.selectGroup(savedGroups.first?.id)
            } else {
                try await self.analyzeMissing()
                try await self.regroupNow()
            }
        }
    }

    private struct AnalysisOutcome {
        let id: String
        let date: Date?
        let result: Result<LocalAnalysis, Error>
    }

    nonisolated private static func analyze(id: String, url: URL) -> AnalysisOutcome {
        AnalysisOutcome(id: id, date: ImageLoader.captureDate(at: url), result: Result { try LocalAnalyzer.analyze(url: url) })
    }

    private func analyzeMissing() async throws {
        let todo = photos.values.filter { $0.analysis == nil }.map { ($0.id, $0.displayURL) }
        guard !todo.isEmpty else { return }
        statusText = "本地分析中（清晰度、人脸、闭眼、曝光）…"
        progress = 0

        let limit = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)
        var failures: [String] = []
        var done = 0
        await withTaskGroup(of: AnalysisOutcome.self) { group in
            var next = 0
            func enqueue() {
                guard next < todo.count else { return }
                let (id, url) = todo[next]
                next += 1
                group.addTask { Self.analyze(id: id, url: url) }
            }
            for _ in 0..<min(limit, todo.count) { enqueue() }
            while let outcome = await group.next() {
                photos[outcome.id]?.captureDate = outcome.date
                switch outcome.result {
                case .success(let analysis): photos[outcome.id]?.analysis = analysis
                case .failure(let error): failures.append("\(outcome.id)：\(error.localizedDescription)")
                }
                done += 1
                progress = Double(done) / Double(todo.count)
                statusText = "本地分析中 \(done)/\(todo.count)"
                enqueue()
            }
        }
        if !failures.isEmpty {
            alert = AlertInfo(
                title: "有 \(failures.count) 张照片分析失败",
                message: failures.prefix(5).joined(separator: "\n") + (failures.count > 5 ? "\n…" : "")
            )
        }
    }

    /// 修改分组参数后重新分组；已有的分析结果和手动选片都保留
    func regroup() {
        perform("正在重新分组…") { try await self.regroupNow() }
    }

    private func regroupNow() async throws {
        statusText = "正在按连拍分组…"
        let list = Array(photos.values)
        let params = AppSettings.cullingParams
        groups = try await Task.detached { try Culling.group(list, params: params) }.value
        Culling.score(&photos, groups: groups, blurThreshold: params.blurThreshold)
        applyAutoDecisions()
        selectGroup(groups.first?.id)
        scheduleSave()
    }

    // MARK: - AI 选片

    func runAI(all: Bool) {
        Task {
            guard let client = await makeVisionClient() else { return }
            perform("AI 选片中…") { try await self.rankWithAI(client: client, all: all) }
        }
    }

    /// 看图模型客户端，AI 选片和定位干扰物共用；配置有问题时弹提示并返回 nil
    private func makeVisionClient() async -> VisionChatClient? {
        let text = AppSettings.baseURL.trimmingCharacters(in: .whitespaces)
        guard let baseURL = URL(string: text), baseURL.scheme?.hasPrefix("http") == true else {
            alert = AlertInfo(title: "选片模型地址无效", message: "请在「AI选片 › 设置…」里检查接口地址：\(text)")
            return nil
        }
        do {
            return VisionChatClient(
                baseURL: baseURL,
                apiKey: try await KeychainStore.loadIfSaved(account: AppSettings.keychainAccount) ?? "",
                model: AppSettings.model
            )
        } catch {
            alert = AlertInfo(title: "读取 API 密钥失败", message: error.localizedDescription)
            return nil
        }
    }

    private struct BatchOutcome {
        let verdicts: Result<[String: AIVerdict], Error>
    }

    private func rankWithAI(client: VisionChatClient, all: Bool) async throws {
        let targets = all ? groups : groups.filter { !members(of: $0).contains { $0.ai != nil } }
        guard !targets.isEmpty else {
            alert = AlertInfo(title: "所有组都已经过 AI 选片", message: "如需重新评估，请选择「全部重新 AI 选片」。")
            return
        }
        let ranker = AIRanker(client: client)
        let batches = AIRanker.batches(groups: targets, photos: photos, perGroup: AppSettings.perGroup)
        if all {
            for id in targets.flatMap(\.photoIDs) { photos[id]?.ai = nil }
        }

        progress = 0
        statusText = "AI 选片中 0/\(batches.count) 批"
        var failures: [String] = []
        var done = 0
        await withTaskGroup(of: BatchOutcome.self) { group in
            var next = 0
            func enqueue() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask {
                    do {
                        return BatchOutcome(verdicts: .success(try await ranker.rank(batch)))
                    } catch {
                        return BatchOutcome(verdicts: .failure(error))
                    }
                }
            }
            // 并发 3 个请求，兼顾速度和接口限流
            for _ in 0..<min(3, batches.count) { enqueue() }
            while let outcome = await group.next() {
                switch outcome.verdicts {
                case .success(let verdicts):
                    for (id, verdict) in verdicts { photos[id]?.ai = verdict }
                case .failure(let error):
                    failures.append(error.localizedDescription)
                }
                done += 1
                progress = Double(done) / Double(batches.count)
                statusText = "AI 选片中 \(done)/\(batches.count) 批"
                applyAutoDecisions()
                enqueue()
            }
        }
        scheduleSave()
        if !failures.isEmpty {
            alert = AlertInfo(
                title: "\(failures.count)/\(batches.count) 批请求失败",
                message: "成功的部分已保存，再点一次「AI 选片」会只处理剩下的组。\n\n\(failures[0])"
            )
        }
    }

    /// 没有被用户手动标记的照片：有 AI 结果按 AI 推荐，否则每组预选本地评分最高且无明显问题的一张
    private func applyAutoDecisions() {
        for group in groups {
            let list = members(of: group)
            let hasAI = list.contains { $0.ai != nil }
            let localBest = list
                .filter { !$0.flags.contains(.blurry) && !$0.flags.contains(.eyesClosed) }
                .max { $0.localScore < $1.localScore }?.id
            for photo in list where !photo.decidedByUser {
                let pick = hasAI ? (photo.ai?.pick ?? false) : photo.id == localBest
                photos[photo.id]?.decision = pick ? .pick : .none
            }
        }
    }

    // MARK: - 选片操作

    func setDecision(_ decision: Decision, for id: String? = nil) {
        guard let id = id ?? selectedPhotoID else { return }
        setDecision(decision, for: [id])
    }

    /// 批量标记整批算一步撤销
    func setDecision(_ decision: Decision, for ids: [String]) {
        guard !ids.isEmpty else { return }
        let label = decision == .pick ? "选用" : decision == .reject ? "淘汰" : "取消标记"
        recordUndo(.decision, ids: ids, label: ids.count > 1 ? "\(label) \(ids.count) 张" : label)
        for id in ids {
            photos[id]?.decision = decision
            photos[id]?.decidedByUser = true
        }
        scheduleSave()
    }

    /// 网格里作用于选中的多张，大图里作用于当前照片
    private var decisionTargets: [String] {
        if gridMode, !gridSelection.isEmpty { return gridPhotoIDs.filter(gridSelection.contains) }
        return selectedPhotoID.map { [$0] } ?? []
    }

    func setRating(_ rating: Int) {
        guard let id = selectedPhotoID else { return }
        recordUndo(.decision, ids: [id], label: "星级")
        photos[id]?.rating = rating
        if rating > 0 { photos[id]?.decision = .pick }
        photos[id]?.decidedByUser = true
        scheduleSave()
    }

    func handleKey(_ characters: String) {
        switch characters.lowercased() {
        case "p": setDecision(.pick, for: decisionTargets)
        case "x": setDecision(.reject, for: decisionTargets)
        case "u": setDecision(.none, for: decisionTargets)
        case "g": toggleGrid()
        case "f": showFaces.toggle()
        case "\\": compareMode.toggle()
        case "k": showPeaking.toggle()
        case "j": showClipping.toggle()
        case "a": autoAdjustSelected()
        case "b": toggleBrush()
        case "z": zoom.cycle()
        case "[": brushSize = max(0.005, brushSize / 1.25)
        case "]": brushSize = min(0.2, brushSize * 1.25)
        case "1", "2", "3", "4", "5": setRating(Int(characters) ?? 0)
        case "0": setRating(0)
        default: break
        }
    }

    // MARK: - 调色

    /// 滑块拖动时会连续调用，记录撤销由 beginEditChange 在拖动开始时做一次
    func updateEdit(_ edit: EditSettings, recordingUndo label: String? = nil) {
        guard let id = selectedPhotoID else { return }
        if let label { recordUndo(.edit, ids: [id], label: label) }
        photos[id]?.edit = edit == .neutral ? nil : edit
        scheduleSave()
    }

    func autoAdjustSelected() {
        guard let photo = selectedPhoto else { return }
        perform("自动调色中…") {
            let url = photo.editURL, analysis = photo.analysis
            let edit = try await Task.detached { try AutoAdjuster.compute(url: url, analysis: analysis) }.value
            self.recordUndo(.edit, ids: [photo.id], label: "自动调色")
            self.photos[photo.id]?.edit = edit
            self.scheduleSave()
        }
    }

    /// 同一组连拍光线一致，直接复用当前照片的参数，保证整组色调统一
    func syncEditToGroup() {
        guard let edit = selectedPhoto?.edit else { return }
        recordUndo(.edit, ids: selectedPhotos.filter { $0.decision != .reject }.map(\.id), label: "同步到本组")
        for photo in selectedPhotos where photo.decision != .reject {
            photos[photo.id]?.edit = edit
        }
        scheduleSave()
    }

    /// 已选照片各自自动调色（不同场景光线不同，不能共用一套参数）
    func autoAdjustAllPicked() {
        let targets = photos.values.filter { $0.decision == .pick && $0.edit == nil }.map { ($0.id, $0.editURL, $0.analysis) }
        guard !targets.isEmpty else {
            alert = AlertInfo(title: "没有需要自动调色的照片", message: "已选照片都调过色了。想重新调整某张，选中后按 A。")
            return
        }
        recordUndo(.edit, ids: targets.map(\.0), label: "已选照片自动调色")
        perform("自动调色中…") {
            for (index, (id, url, analysis)) in targets.enumerated() {
                let edit = try await Task.detached { try AutoAdjuster.compute(url: url, analysis: analysis) }.value
                self.photos[id]?.edit = edit
                self.progress = Double(index + 1) / Double(targets.count)
                self.statusText = "自动调色中 \(index + 1)/\(targets.count)"
            }
            self.scheduleSave()
        }
    }

    func exportFinishedJPEGs() {
        let picked = photos.values.filter { $0.decision == .pick }
        guard !picked.isEmpty else {
            alert = AlertInfo(title: "还没有已选照片", message: "先选用照片（P），再导出成片。")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "导出到这里"
        panel.message = "导出 \(picked.count) 张已选照片的调色成片（JPG，全尺寸）"
        guard panel.runModal() == .OK, let destination = panel.url, let folder = folderURL else { return }

        perform("正在导出成片…") {
            var exported = 0, skipped = 0
            for (index, photo) in picked.enumerated() {
                let target = destination.appendingPathComponent(photo.fileName).appendingPathExtension("jpg")
                if FileManager.default.fileExists(atPath: target.path) {
                    skipped += 1
                } else {
                    try await Task.detached { try PhotoRenderer.exportJPEG(photo, folder: folder, to: target, quality: 0.92) }.value
                    exported += 1
                }
                self.progress = Double(index + 1) / Double(picked.count)
                self.statusText = "正在导出成片 \(index + 1)/\(picked.count)"
            }
            var message = "已导出 \(exported) 张成片到「\(destination.lastPathComponent)」。"
            if skipped > 0 { message += "\n有 \(skipped) 个同名文件已存在，已跳过。" }
            self.alert = AlertInfo(title: "导出完成", message: message)
        }
    }

    // MARK: - 个人风格

    /// 选原图文件夹和修好的成片文件夹，按文件名配对后学习调色风格
    func learnStyle() {
        func chooseFolder(_ message: String) -> URL? {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "选择"
            panel.message = message
            return panel.runModal() == .OK ? panel.url : nil
        }
        guard let originals = chooseFolder("第 1 步：选择原图文件夹（RAW 或相机直出 JPG）"),
              let finished = chooseFolder("第 2 步：选择修好的成片文件夹（例如像素蛋糕导出的 JPG，文件名与原图相同）")
        else { return }
        let name = "\(finished.lastPathComponent) 风格"
        perform("正在学习你的修图风格…") {
            let pairs = try StyleLearner.pairs(originals: originals, finished: finished)
            self.statusText = "正在学习你的修图风格（\(pairs.count) 对样片）…"
            let preset = try await Task.detached { try StyleLearner.learn(name: name, pairs: pairs) { _ in } }.value
            try StyleStore.shared.save(preset)
            self.styles = try StyleStore.shared.all()
            self.alert = AlertInfo(
                title: "风格已学会",
                message: "「\(preset.name)」来自 \(pairs.count) 对样片。在右侧「修图 › 风格」里选择即可套用；样片越多（建议 20 对以上、覆盖不同光线），效果越稳定。"
            )
        }
    }

    func deleteStyle(_ id: UUID) {
        do {
            try StyleStore.shared.delete(id)
            styles = try StyleStore.shared.all()
        } catch {
            alert = AlertInfo(title: "删除风格失败", message: error.localizedDescription)
        }
    }

    /// 把当前照片的风格设置套用到所有已选照片（保留各自的曝光等微调）
    func applyStyleToAllPicked() {
        guard let source = selectedPhoto?.edit else { return }
        recordUndo(.edit, ids: photos.values.filter { $0.decision == .pick }.map(\.id), label: "套用风格到全部已选")
        for photo in photos.values where photo.decision == .pick {
            var edit = photo.edit ?? .neutral
            edit.styleID = source.styleID
            edit.styleStrength = source.styleStrength
            edit.skinSmoothing = source.skinSmoothing
            photos[photo.id]?.edit = edit
        }
        scheduleSave()
    }

    // MARK: - 去杂物

    func toggleBrush() {
        brushMode.toggle()
        if !brushMode { strokes = [] }
    }

    func beginStroke(at point: CGPoint) {
        strokes.append(BrushStroke(points: [point], radius: brushSize))
    }

    func extendStroke(to point: CGPoint) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].points.append(point)
    }

    /// 回车：消除当前照片的涂抹；⇧回车：整组同一位置一起消除
    func runCleanup(wholeGroup: Bool = false) {
        guard let photo = selectedPhoto else { return }
        guard !strokes.isEmpty else {
            alert = AlertInfo(title: "还没有涂抹", message: "按 B 进入画笔模式，在大图上涂抹要去掉的物体，再点「消除」。")
            return
        }
        let targets = wholeGroup ? selectedPhotos.filter { $0.decision != .reject }.map(\.id) : [photo.id]
        for id in targets {
            enqueueCleanup(photoID: id, strokes: strokes, itemName: nil, isLarge: false)
        }
        strokes = []
    }

    func enqueueCleanup(photoID: String, strokes: [BrushStroke], itemName: String?, isLarge: Bool) {
        cleanupJobs.append(CleanupJob(photoID: photoID, strokes: strokes, itemName: itemName, isLarge: isLarge))
        pumpCleanupQueue()
    }

    func isCleaning(_ photoID: String) -> Bool {
        locatingPhotoIDs.contains(photoID) || cleanupJobs.contains { $0.photoID == photoID }
    }

    // MARK: - 一键去干扰物 / 一键初修

    /// 单张：让 AI 找出干扰物，背景杂物直接排队去除，主体相关物品只记录
    func removeDistractions() {
        guard let id = selectedPhotoID else { return }
        Task {
            guard let client = await makeVisionClient() else { return }
            await locateAndRemove(photoID: id, client: client)
        }
    }

    /// 消除区域超过画面的 4% 时提示检查：大面积补全更容易出错
    private static let largeAreaThreshold: CGFloat = 0.04

    @discardableResult
    private func locateAndRemove(photoID: String, client: VisionChatClient) async -> Bool {
        guard let photo = photos[photoID] else { return false }
        let url = photo.displayURL, hints = photo.ai?.distractions ?? []
        locatingPhotoIDs.insert(photoID)
        defer { locatingPhotoIDs.remove(photoID) }
        do {
            let locator = DistractionLocator(client: client)
            async let items = locator.locate(imageURL: url, hints: hints)
            async let size = Task.detached { ImageLoader.orientedPixelSize(at: url) }.value
            let (found, pixelSize) = try await (items, size)
            guard photos[photoID] != nil else { return false }
            let aspect = pixelSize.map { $0.width / $0.height } ?? 1.5
            for item in found {
                if item.isBackground {
                    enqueueCleanup(
                        photoID: photoID,
                        strokes: DistractionLocator.strokes(covering: item.box, imageAspect: aspect),
                        itemName: item.name,
                        isLarge: item.box.width * item.box.height > Self.largeAreaThreshold
                    )
                } else {
                    appendLog(photoID) { $0.kept.append(item.name) }
                }
            }
            if !found.contains(where: \.isBackground) {
                appendLog(photoID) { $0.actions.append("没有发现需要去除的干扰物") }
            }
            scheduleSave()
            return true
        } catch {
            appendLog(photoID) { $0.warnings.append("识别干扰物失败：\(error.localizedDescription)") }
            scheduleSave()
            return false
        }
    }

    /// 一键初修：对所有已选照片全自动处理，不需要事先过目；完成后给出总结
    func startQuickRetouch(styleID: UUID?) {
        let targets = photos.values.filter { $0.decision == .pick }.sorted { $0.id < $1.id }
        guard !targets.isEmpty else {
            alert = AlertInfo(title: "还没有已选照片", message: "先选用照片（P），再做一键初修。")
            return
        }
        Task { await runQuickRetouch(targets, styleID: styleID) }
    }

    private func runQuickRetouch(_ targets: [Photo], styleID: UUID?) async {
        guard let client = await makeVisionClient() else { return }
        recordUndo(.edit, ids: targets.map(\.id), label: "一键初修")
        for photo in targets { photos[photo.id]?.retouchLog = RetouchLog() }
        retouchProgress = (0, targets.count)
        let styleName = styles.first { $0.id == styleID }?.name

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue() {
                guard next < targets.count else { return }
                let photo = targets[next]
                next += 1
                group.addTask { await self.retouch(photo, styleID: styleID, styleName: styleName, client: client) }
            }
            // 每张要调用看图模型定位干扰物，并发 3 个
            for _ in 0..<min(3, targets.count) { enqueue() }
            for await _ in group {
                if let progress = retouchProgress { retouchProgress = (progress.done + 1, progress.total) }
                enqueue()
            }
        }
        scheduleSave()
        // 去杂物还在后台排队时，等它们做完再弹总结
        while !cleanupJobs.isEmpty { try? await Task.sleep(for: .seconds(1)) }
        retouchProgress = nil
        showRetouchSummary = true
    }

    private func retouch(_ photo: Photo, styleID: UUID?, styleName: String?, client: VisionChatClient) async {
        // 调色：手动修过的保留，不覆盖摄影师的调整
        if let existing = photo.edit {
            appendLog(photo.id) { $0.actions.append("已有手动修图，保留原调整") }
            if let styleID, existing.styleID == nil {
                var edit = existing
                edit.styleID = styleID
                photos[photo.id]?.edit = edit
                appendLog(photo.id) { $0.actions.append("套用风格「\(styleName ?? "")」") }
            }
        } else {
            let url = photo.editURL, analysis = photo.analysis
            do {
                var edit = try await Task.detached { try AutoAdjuster.compute(url: url, analysis: analysis) }.value
                if analysis?.faces.contains(where: { $0.features != nil }) == true { edit.skinSmoothing = 0.25 }
                edit.styleID = styleID
                photos[photo.id]?.edit = edit
                appendLog(photo.id) { $0.actions.append(contentsOf: Self.describe(edit, styleName: styleName)) }
            } catch {
                appendLog(photo.id) { $0.warnings.append("自动调色失败：\(error.localizedDescription)") }
            }
        }
        // 初修修不了的问题：来自本地检测和 AI 选片
        let unfixable = photo.flags.map { "\($0.label)，初修无法修复" } + (photo.ai?.issues ?? [])
        if !unfixable.isEmpty { appendLog(photo.id) { $0.unfixable.append(contentsOf: unfixable) } }
        await locateAndRemove(photoID: photo.id, client: client)
    }

    private static func describe(_ edit: EditSettings, styleName: String?) -> [String] {
        var parts: [String] = []
        if abs(edit.exposure) >= 0.05 { parts.append(String(format: "曝光 %+.2f EV", edit.exposure)) }
        if edit.temperature != 6500 || edit.tint != 0 {
            parts.append(edit.temperature > 6500 ? "白平衡校正（偏冷 → 回暖）" : "白平衡校正（偏暖 → 中性）")
        }
        if edit.highlights < 0 { parts.append("压暗高光") }
        if edit.shadows > 0 { parts.append("提亮阴影") }
        if edit.skinSmoothing > 0 { parts.append("皮肤轻度柔化") }
        if let styleName, edit.styleID != nil { parts.append("套用风格「\(styleName)」") }
        return parts.isEmpty ? ["曝光和白平衡正常，未调整"] : parts
    }

    /// 同一张照片的任务按顺序做（后一次要叠在前一次的结果上），不同照片可以并行
    private func pumpCleanupQueue() {
        guard let folder = folderURL else { return }
        while cleanupJobs.filter(\.isRunning).count < Self.cleanupConcurrency,
              let index = cleanupJobs.firstIndex(where: { job in
                  !job.isRunning && !cleanupJobs.contains { $0.isRunning && $0.photoID == job.photoID }
              }) {
            cleanupJobs[index].isRunning = true
            let job = cleanupJobs[index]
            Task { await runCleanupJob(job, folder: folder) }
        }
    }

    private func runCleanupJob(_ job: CleanupJob, folder: URL) async {
        let outcome: Result<CleanupPatch, Error>
        do {
            guard let photo = photos[job.photoID] else { throw CleanupEngine.CleanupError.unreadable }
            let provider = try await InpaintService.makeProvider()
            outcome = .success(try await CleanupEngine.run(photo: photo, strokes: job.strokes, folder: folder, provider: provider))
        } catch {
            outcome = .failure(error)
        }
        cleanupJobs.removeAll { $0.id == job.id }
        // 等待期间换了文件夹：结果属于旧文件夹，丢弃（修补文件留在旧文件夹，下次打开时清理）
        guard folderURL == folder, photos[job.photoID] != nil else { return }

        let name = photos[job.photoID]?.fileName ?? job.photoID
        switch outcome {
        case .success(let patch):
            // 先读后写：@Observable 属性在写入期间再读取同一属性会触发独占访问冲突而崩溃
            let patches = (photos[job.photoID]?.cleanups ?? []) + [patch]
            recordUndo(.cleanups, ids: [job.photoID], label: job.itemName.map { "去掉\($0)" } ?? "去杂物")
            photos[job.photoID]?.cleanups = patches
            if let item = job.itemName {
                appendLog(job.photoID) {
                    if job.isLarge {
                        $0.warnings.append("去掉了\(item)，消除区域较大，建议对比检查")
                    } else {
                        $0.actions.append("去掉了\(item)")
                    }
                }
            }
        case .failure(let error):
            cleanupFailures.append("\(name)：\(error.localizedDescription)")
            if let item = job.itemName {
                appendLog(job.photoID) { $0.warnings.append("去掉\(item)失败：\(error.localizedDescription)") }
            }
        }
        scheduleSave()
        pumpCleanupQueue()
        if cleanupJobs.isEmpty, !cleanupFailures.isEmpty {
            alert = AlertInfo(
                title: "\(cleanupFailures.count) 处去杂物失败",
                message: cleanupFailures.prefix(5).joined(separator: "\n") + (cleanupFailures.count > 5 ? "\n…" : "")
            )
            cleanupFailures = []
        }
    }

    private func appendLog(_ photoID: String, _ change: (inout RetouchLog) -> Void) {
        var log = photos[photoID]?.retouchLog ?? RetouchLog()
        change(&log)
        photos[photoID]?.retouchLog = log
    }

    func undoCleanup() {
        guard let id = selectedPhotoID, var patches = photos[id]?.cleanups, !patches.isEmpty else { return }
        recordUndo(.cleanups, ids: [id], label: "撤销上一次消除")
        patches.removeLast()
        photos[id]?.cleanups = patches.isEmpty ? nil : patches
        scheduleSave()
    }

    // MARK: - 放大

    /// 空格：适应窗口时放大到 100% 并对准人脸（没有人脸时对准人体），已放大时回到适应窗口
    func zoomToFocus() {
        guard zoom.pixelRatio == nil else {
            zoom.pixelRatio = nil
            return
        }
        let focus = selectedPhoto?.analysis?.focusRect
        zoom = ZoomState(pixelRatio: 1, center: focus.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: 0.5, y: 0.5))
    }

    // MARK: - 撤销 / 重做

    /// 在改动前调用：记下这些照片该类字段的旧值，并清空重做记录
    private func recordUndo(_ kind: UndoKind, ids: [String], label: String) {
        guard !ids.isEmpty else { return }
        let before = Dictionary(uniqueKeysWithValues: ids.compactMap { id in photos[id].map { (id, $0) } })
        undoStack.append(UndoEntry(kind: kind, label: label, before: before))
        redoStack = []
    }

    /// 滑块开始拖动时记一次，整次拖动算一步
    func beginEditChange(_ label: String) {
        guard let id = selectedPhotoID else { return }
        recordUndo(.edit, ids: [id], label: label)
    }

    func undo() {
        // 画笔模式下先撤销还没消除的笔触
        if brushMode, !strokes.isEmpty {
            strokes.removeLast()
            return
        }
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(swap(entry))
        scheduleSave()
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(swap(entry))
        scheduleSave()
    }

    /// 用记录里的旧值替换当前值，返回替换前的当前值，供反方向操作使用
    private func swap(_ entry: UndoEntry) -> UndoEntry {
        var current: [String: Photo] = [:]
        for (id, saved) in entry.before {
            guard var photo = photos[id] else { continue }
            current[id] = photo
            switch entry.kind {
            case .decision:
                photo.decision = saved.decision
                photo.decidedByUser = saved.decidedByUser
                photo.rating = saved.rating
            case .edit:
                photo.edit = saved.edit
            case .cleanups:
                photo.cleanups = saved.cleanups
            }
            photos[id] = photo
        }
        // 撤销后跳到受影响的照片，让用户看到改了什么
        if let id = entry.before.keys.first, entry.before.count == 1, let group = groups.first(where: { $0.photoIDs.contains(id) }) {
            selectGroup(group.id, photoID: id)
        }
        return UndoEntry(kind: entry.kind, label: entry.label, before: current)
    }

    /// 撤销去杂物后修补文件仍保留（以便重做），换文件夹时清掉不再被引用的修补文件
    private func removeUnusedPatches(folder: URL) throws {
        let directory = CleanupEngine.patchDirectory(folder: folder)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let used = Set(photos.values.flatMap { $0.cleanups ?? [] }.map { "\($0.id.uuidString).png" })
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) where !used.contains(file) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    // MARK: - 网格总览

    /// 网格里的照片顺序：按当前筛选下的组依次排列
    var gridPhotoIDs: [String] { visibleGroups.flatMap(\.photoIDs) }

    func toggleGrid() {
        gridMode.toggle()
        brushMode = false
        strokes = []
        if gridMode { gridSelection = selectedPhotoID.map { [$0] } ?? [] }
    }

    /// 单击选中一张；⌘ 单击增减；⇧ 单击选中连续范围
    func gridClick(_ id: String, command: Bool, shift: Bool) {
        if shift, let anchor = selectedPhotoID {
            let order = gridPhotoIDs
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
                gridSelection.formUnion(order[min(a, b)...max(a, b)])
            }
        } else if command {
            if gridSelection.contains(id) { gridSelection.remove(id) } else { gridSelection.insert(id) }
        } else {
            gridSelection = [id]
        }
        moveCurrent(to: id)
    }

    /// 框选：按住 ⌘ 时在已有选择上追加
    func gridMarquee(_ ids: Set<String>, adding: Bool) {
        gridSelection = adding ? gridSelection.union(ids) : ids
        if let first = gridPhotoIDs.first(where: ids.contains) { moveCurrent(to: first) }
    }

    /// 方向键在网格里移动：左右一张，上下一组
    func gridStep(by delta: Int) {
        let order = gridPhotoIDs
        guard let index = order.firstIndex(where: { $0 == selectedPhotoID }) ?? order.indices.first else { return }
        let target = order[min(order.count - 1, max(0, index + delta))]
        gridSelection = [target]
        moveCurrent(to: target)
    }

    func gridStepGroup(by delta: Int) {
        stepGroup(by: delta)
        gridSelection = selectedPhotoID.map { [$0] } ?? []
    }

    func openInViewer(_ id: String) {
        moveCurrent(to: id)
        gridMode = false
    }

    private func moveCurrent(to id: String) {
        guard let group = groups.first(where: { $0.photoIDs.contains(id) }) else { return }
        selectGroup(group.id, photoID: id)
    }

    // MARK: - 导航

    func selectGroup(_ id: Int?, photoID: String? = nil) {
        selectedGroupID = id
        strokes = []
        guard let group = selectedGroup else {
            selectedPhotoID = nil
            return
        }
        selectedPhotoID = photoID ?? representative(of: group)?.id
    }

    func selectPhoto(_ id: String) {
        selectedPhotoID = id
        strokes = []
    }

    func nextPhoto() { stepPhoto(by: 1) }
    func previousPhoto() { stepPhoto(by: -1) }
    func nextGroup() { stepGroup(by: 1) }
    func previousGroup() { stepGroup(by: -1) }

    /// 到达组的首尾时跨到相邻组
    private func stepPhoto(by delta: Int) {
        let list = selectedPhotos
        guard let current = list.firstIndex(where: { $0.id == selectedPhotoID }) else { return }
        let target = current + delta
        if list.indices.contains(target) {
            selectPhoto(list[target].id)
            return
        }
        let visible = visibleGroups
        guard let groupIndex = visible.firstIndex(where: { $0.id == selectedGroupID }),
              visible.indices.contains(groupIndex + delta)
        else { return }
        let group = visible[groupIndex + delta]
        selectGroup(group.id, photoID: delta > 0 ? group.photoIDs.first : group.photoIDs.last)
    }

    private func stepGroup(by delta: Int) {
        let visible = visibleGroups
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == selectedGroupID }.map { $0 + delta } ?? 0
        guard visible.indices.contains(index) else { return }
        selectGroup(visible[index].id)
    }

    // MARK: - 导出

    func writeXMP() {
        perform("正在写入 XMP 星级…") {
            let targets = self.photos.values.filter { $0.exportRating != nil }
            let result = try await Task.detached { () -> (written: Int, jpegOnly: Int) in
                var written = 0, jpegOnly = 0
                for photo in targets {
                    guard let raw = photo.rawURL, let rating = photo.exportRating else {
                        jpegOnly += 1
                        continue
                    }
                    try XMPWriter.writeRating(rating, forRAW: raw)
                    written += 1
                }
                return (written, jpegOnly)
            }.value
            var message = "已为 \(result.written) 张 RAW 写入星级：选用为 3 星（或你打的星级），淘汰为「拒绝」。在 Lightroom 里对这些照片执行「从文件读取元数据」即可看到。"
            if result.jpegOnly > 0 {
                message += "\n\n另有 \(result.jpegOnly) 张只有 JPG，XMP 附属文件对 JPG 无效，请用「拷贝已选照片到文件夹」。"
            }
            self.alert = AlertInfo(title: "写入完成", message: message)
        }
    }

    func copyPicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "拷贝到这里"
        panel.message = "选择存放已选照片的文件夹（RAW 和 JPG 都会拷贝）"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let files = photos.values.filter { $0.decision == .pick }.flatMap { [$0.rawURL, $0.renderedURL].compactMap { $0 } }
        perform("正在拷贝已选照片…") {
            let result = try await Task.detached { () -> (copied: Int, skipped: Int) in
                var copied = 0, skipped = 0
                for file in files {
                    let target = destination.appendingPathComponent(file.lastPathComponent)
                    if FileManager.default.fileExists(atPath: target.path) {
                        skipped += 1
                        continue
                    }
                    try FileManager.default.copyItem(at: file, to: target)
                    copied += 1
                }
                return (copied, skipped)
            }.value
            var message = "已拷贝 \(result.copied) 个文件到「\(destination.lastPathComponent)」。"
            if result.skipped > 0 { message += "\n有 \(result.skipped) 个同名文件已存在，已跳过。" }
            self.alert = AlertInfo(title: "拷贝完成", message: message)
        }
    }

    // MARK: - 工具

    private func perform(_ title: String, _ work: @escaping () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        statusText = title
        progress = 0
        Task {
            do {
                try await work()
            } catch {
                alert = AlertInfo(title: "出错了", message: error.localizedDescription)
            }
            isBusy = false
            statusText = ""
        }
    }

    /// 选片操作很频繁，合并 1 秒内的修改再写盘
    private func scheduleSave() {
        saveTask?.cancel()
        guard let folder = folderURL else { return }
        let session = Session(photos: Array(photos.values), groups: groups)
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            do {
                try await Task.detached { try SessionStore.save(session, folder: folder) }.value
            } catch {
                alert = AlertInfo(title: "保存选片记录失败", message: error.localizedDescription)
            }
        }
    }
}
