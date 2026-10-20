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
        /// 重画指令（对话改图）；nil 表示去掉涂抹区域里的物体
        var prompt: String? = nil
        /// 来自对话改图：结果回写到对话里，不进初修记录
        var fromChat = false
        var isRunning = false
    }

    var cleanupJobs: [CleanupJob] = []
    /// 正在让 AI 识别干扰物位置的照片
    var locatingPhotoIDs: Set<String> = []
    /// 右侧面板：选片时只看判断用的信息，修图时用工具栏切换工具。两者都记住上次的选择
    var inspectorMode: InspectorMode = InspectorMode(rawValue: UserDefaults.standard.string(forKey: "inspectorMode") ?? "") ?? .culling {
        didSet {
            UserDefaults.standard.set(inspectorMode.rawValue, forKey: "inspectorMode")
            if inspectorMode == .culling { exitBrush() }
        }
    }
    var editTool: EditTool = EditTool(rawValue: UserDefaults.standard.string(forKey: "editTool") ?? "") ?? .adjust {
        didSet {
            UserDefaults.standard.set(editTool.rawValue, forKey: "editTool")
            // 画笔只属于去杂物工具：离开时关掉，避免在看不到画笔设置时误涂
            if editTool != .cleanup { exitBrush() }
        }
    }
    /// 多图合成进行中；nil 表示没有在合成
    var composite: CompositeSession?
    var showCompositePicker = false
    /// 正在等模型理解指令的照片
    var chattingPhotoIDs: Set<String> = []
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
    /// 修图预设（风格、磨皮、调色偏移和给 AI 的描述），全局共用
    var presets: [RetouchPreset] = []
    var defaultPresetID: UUID?
    var showPresetManager = false
    var showSavePreset = false
    /// 最近一次 AI 对本场诉求的理解，初修总结里展示
    var lastLookSummary: String?
    var showUsage = false
    /// 最近一次一键初修的起止时间，初修总结里按它统计本次花费
    var lastRetouchWindow: (start: Date, end: Date)?

    init() {
        do {
            styles = try StyleStore.shared.all()
        } catch {
            alert = AlertInfo(title: "读取风格预设失败", message: error.localizedDescription)
        }
        do {
            presets = try RetouchPresetStore.load()
            defaultPresetID = RetouchPresetStore.defaultID.flatMap { id in presets.contains { $0.id == id } ? id : nil }
        } catch {
            alert = AlertInfo(title: "读取修图预设失败", message: error.localizedDescription)
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
        inspectorMode = .culling
        UsageLog.shared.setShoot(folder.lastPathComponent)
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
            guard let client = await makeVisionClient(purpose: .culling) else { return }
            perform("AI 选片中…") { try await self.rankWithAI(client: client, all: all) }
        }
    }

    /// 看图模型客户端，AI 选片和定位干扰物共用；配置有问题时弹提示并返回 nil
    private func makeVisionClient(model: String = AppSettings.model, purpose: AIPurpose) async -> VisionChatClient? {
        let text = AppSettings.baseURL.trimmingCharacters(in: .whitespaces)
        guard let baseURL = URL(string: text), baseURL.scheme?.hasPrefix("http") == true else {
            alert = AlertInfo(title: "选片模型地址无效", message: "请在「小宇专属 › 设置…」里检查接口地址：\(text)")
            return nil
        }
        do {
            return VisionChatClient(
                baseURL: baseURL,
                apiKey: try await KeychainStore.loadIfSaved(account: AppSettings.keychainAccount) ?? "",
                model: model,
                purpose: purpose
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
        if brushMode { showTool(.cleanup) } else { strokes = [] }
    }

    private func exitBrush() {
        guard brushMode else { return }
        brushMode = false
        strokes = []
    }

    /// 切到修图模式并选中某个工具（画笔、对话改图等入口调用）
    func showTool(_ tool: EditTool) {
        inspectorMode = .editing
        editTool = tool
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
            guard let client = await makeVisionClient(purpose: .locate) else { return }
            await locateAndRemove(photoID: id, client: client)
        }
    }

    /// 消除区域超过画面的 4% 时提示检查：大面积补全更容易出错
    private static let largeAreaThreshold: CGFloat = 0.04

    @discardableResult
    private func locateAndRemove(photoID: String, client: VisionChatClient) async -> Bool {
        guard let photo = photos[photoID] else { return false }
        let url = photo.displayURL, hints = photo.ai?.distractions ?? [], note = photo.retouchNote
        locatingPhotoIDs.insert(photoID)
        defer { locatingPhotoIDs.remove(photoID) }
        do {
            let locator = DistractionLocator(client: client)
            async let items = locator.locate(imageURL: url, hints: hints, note: note)
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
    func startQuickRetouch(presetID: UUID?, note: String) {
        let targets = photos.values.filter { $0.decision == .pick }.sorted { $0.id < $1.id }
        guard !targets.isEmpty else {
            alert = AlertInfo(title: "还没有已选照片", message: "先选用照片（P），再做一键初修。")
            return
        }
        let preset = presets.first { $0.id == presetID }
        Task { await runQuickRetouch(targets, preset: preset, note: note.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private func runQuickRetouch(_ targets: [Photo], preset: RetouchPreset?, note: String) async {
        guard let client = await makeVisionClient(purpose: .locate) else { return }
        recordUndo(.edit, ids: targets.map(\.id), label: "一键初修")
        for photo in targets { photos[photo.id]?.retouchLog = RetouchLog() }
        retouchProgress = (0, targets.count)
        lastLookSummary = nil
        let retouchStart = Date()
        lastRetouchWindow = nil
        // 选了预设或写了诉求：所有照片按预设重新调色（用户确认，手动修过的也重做，可撤销）；否则沿用原来的自动调色
        let usesPreset = preset != nil || !note.isEmpty
        if usesPreset {
            statusText = note.isEmpty ? "按预设调色中…" : "AI 正在理解本场诉求…"
            await recolor(targets.map(\.id), preset: preset, note: note)
            statusText = ""
        }

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func enqueue() {
                guard next < targets.count else { return }
                let photo = targets[next]
                next += 1
                group.addTask { await self.retouch(photo, adjustsColor: !usesPreset, client: client) }
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
        lastRetouchWindow = (retouchStart, Date())
        showRetouchSummary = true
    }

    /// adjustsColor 为 false 时调色已由 recolor 按预设统一做过，这里只去杂物
    private func retouch(_ photo: Photo, adjustsColor: Bool, client: VisionChatClient) async {
        // 调色：手动修过的保留，不覆盖摄影师的调整
        if !adjustsColor {
        } else if photo.edit != nil {
            appendLog(photo.id) { $0.actions.append("已有手动修图，保留原调整") }
        } else {
            let url = photo.editURL, analysis = photo.analysis
            do {
                var edit = try await Task.detached { try AutoAdjuster.compute(url: url, analysis: analysis) }.value
                if analysis?.faces.contains(where: { $0.features != nil }) == true { edit.skinSmoothing = 0.25 }
                photos[photo.id]?.edit = edit
                appendLog(photo.id) { $0.actions.append(contentsOf: Self.describe(edit, presetName: nil)) }
            } catch {
                appendLog(photo.id) { $0.warnings.append("自动调色失败：\(error.localizedDescription)") }
            }
        }
        // 初修修不了的问题：来自本地检测和 AI 选片
        let unfixable = photo.flags.map { "\($0.label)，初修无法修复" } + (photo.ai?.issues ?? [])
        if !unfixable.isEmpty { appendLog(photo.id) { $0.unfixable.append(contentsOf: unfixable) } }
        await locateAndRemove(photoID: photo.id, client: client)
    }

    private static func describe(_ edit: EditSettings, presetName: String?) -> [String] {
        var parts: [String] = []
        if abs(edit.exposure) >= 0.05 { parts.append(String(format: "曝光 %+.2f EV", edit.exposure)) }
        if edit.temperature != 6500 || edit.tint != 0 {
            parts.append(edit.temperature > 6500 ? "白平衡校正（偏冷 → 回暖）" : "白平衡校正（偏暖 → 中性）")
        }
        if edit.highlights < 0 { parts.append("压暗高光") }
        if edit.shadows > 0 { parts.append("提亮阴影") }
        if edit.skinSmoothing > 0 { parts.append(String(format: "皮肤柔化 %.0f%%", edit.skinSmoothing * 100)) }
        if let presetName { parts.insert("套用预设「\(presetName)」", at: 0) }
        return parts.isEmpty ? ["曝光和白平衡正常，未调整"] : parts
    }

    /// 同一张照片的任务按顺序做（后一次要叠在前一次的结果上），不同照片可以并行
    func pumpCleanupQueue() {
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
            let purpose: AIPurpose = job.fromChat ? .chatRedraw : job.prompt == Compositor.blendPrompt ? .compositeBlend : .cleanup
            let provider = try await InpaintService.makeProvider(purpose: purpose)
            outcome = .success(try await CleanupEngine.run(
                photo: photo, strokes: job.strokes, prompt: job.prompt, folder: folder, provider: provider
            ))
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
            recordUndo(.cleanups, ids: [job.photoID], label: job.undoLabel)
            photos[job.photoID]?.cleanups = patches
            if job.fromChat {
                appendChat(job.photoID, ChatMessage(role: .assistant, text: "已完成：\(job.undoLabel)"))
            } else if let item = job.itemName {
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
            if job.fromChat {
                appendChat(job.photoID, ChatMessage(
                    role: .assistant, text: "\(job.undoLabel)失败：\(error.localizedDescription)", isError: true
                ))
            } else if let item = job.itemName {
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

    // MARK: - 修图预设

    /// 对一批照片按预设和本场诉求重新调色：每张先按自身光线自动调色，再叠加预设，再叠加整场统一的诉求换算结果。
    /// 去杂物和合成结果不动。调用方负责记录撤销
    private func recolor(_ ids: [String], preset: RetouchPreset?, note: String) async {
        guard let folder = folderURL else { return }
        var autos: [String: EditSettings] = [:], base: [String: EditSettings] = [:]
        for id in ids {
            guard let photo = photos[id] else { continue }
            let url = photo.editURL, analysis = photo.analysis
            do {
                var auto = try await Task.detached { try AutoAdjuster.compute(url: url, analysis: analysis) }.value
                if preset == nil, analysis?.faces.contains(where: { $0.features != nil }) == true { auto.skinSmoothing = 0.25 }
                autos[id] = auto
                base[id] = preset?.applied(to: auto) ?? auto
            } catch {
                appendLog(id) { $0.warnings.append("自动调色失败：\(error.localizedDescription)") }
            }
        }

        var look: LookAdjust?
        if !note.isEmpty, let client = await makeVisionClient(model: AppSettings.chatModel, purpose: .look) {
            // 均匀取最多 4 张代表照片，让模型在已调好的现状上判断幅度
            let sampleIDs = Self.spread(ids.filter { base[$0] != nil }, count: 4)
            let samples = sampleIDs.compactMap { id -> (Photo, EditSettings)? in photos[id].flatMap { p in base[id].map { (p, $0) } } }
            do {
                let images = try await Task.detached {
                    try samples.map { try Self.preview($0.0, edit: $0.1, folder: folder, maxPixel: 768) }
                }.value
                look = try await LookInterpreter(client: client).interpret(note: note, samples: images)
            } catch {
                alert = AlertInfo(title: "AI 没能理解本场诉求", message: "已按预设和自动调色处理，诉求里的颜色要求没有生效。\n\n\(error.localizedDescription)")
            }
        }
        lastLookSummary = look?.summary

        for (id, edit) in base {
            guard let photo = photos[id], let auto = autos[id] else { continue }
            let target = look?.applied(to: edit) ?? edit
            let (final, strength) = await Task.detached { Self.limitClipping(photo, auto: auto, target: target, folder: folder) }.value
            photos[id]?.edit = final
            photos[id]?.retouchNote = note.isEmpty ? nil : note
            var actions = Self.describe(final, presetName: preset?.name) + (look.map { ["按本场诉求：\($0.summary)"] } ?? [])
            if strength < 1 {
                actions.append(String(format: "为避免饱和颜色溢出，本张的预设和诉求调整减弱到 %.0f%%", strength * 100))
            }
            appendLog(id) { $0.actions.append(contentsOf: actions) }
        }
        scheduleSave()
    }

    /// 套用后饱和颜色新增溢出过多时，逐步减弱本张相对自动调色的调整（一半、四分之一）。
    /// 实拍中红房子特写在偏暖加对比后整片红墙到顶、木板纹理消失
    private nonisolated static func limitClipping(
        _ photo: Photo, auto: EditSettings, target: EditSettings, folder: URL
    ) -> (EditSettings, Double) {
        guard let reference = try? preview(photo, edit: auto, folder: folder, maxPixel: 512) else { return (target, 1) }
        let baseline = ClipGuard.clippedFraction(reference)
        for strength in [1.0, 0.5, 0.25] {
            let edit = strength == 1 ? target : ClipGuard.blend(from: auto, to: target, strength)
            guard let image = try? preview(photo, edit: edit, folder: folder, maxPixel: 512) else { return (target, 1) }
            if ClipGuard.clippedFraction(image) - baseline <= ClipGuard.maxNewlyClipped { return (edit, strength) }
        }
        return (ClipGuard.blend(from: auto, to: target, 0.25), 0.25)
    }

    private static func spread(_ ids: [String], count: Int) -> [String] {
        guard ids.count > count else { return ids }
        return (0..<count).map { ids[$0 * (ids.count - 1) / (count - 1)] }
    }

    /// 单张或整批套用预设：只重做调色，去杂物保留；整批算一步撤销
    func applyPreset(_ preset: RetouchPreset, to ids: [String]) {
        guard !ids.isEmpty else { return }
        perform(preset.note.isEmpty ? "套用预设中…" : "AI 正在按预设描述调色…") {
            self.recordUndo(.edit, ids: ids, label: "套用预设「\(preset.name)」")
            await self.recolor(ids, preset: preset, note: preset.note.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    var pickedPhotoIDs: [String] { photos.values.filter { $0.decision == .pick }.map(\.id).sorted() }

    /// 把当前照片的修图存为预设：记下它比自动调色多调的部分，曝光和色温不存
    func saveCurrentAsPreset(name: String, note: String) {
        guard let photo = selectedPhoto else { return }
        let edit = photo.edit ?? .neutral, url = photo.editURL, analysis = photo.analysis
        perform("存为预设中…") {
            let auto = try await Task.detached { try AutoAdjuster.compute(url: url, analysis: analysis) }.value
            self.presets.append(RetouchPreset.from(edit: edit, auto: auto, name: name, note: note))
            try RetouchPresetStore.save(self.presets)
        }
    }

    func updatePreset(_ preset: RetouchPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        savePresets()
    }

    func addPreset() -> RetouchPreset {
        let preset = RetouchPreset(name: "新预设")
        presets.append(preset)
        savePresets()
        return preset
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        if defaultPresetID == id { setDefaultPreset(nil) }
        savePresets()
    }

    func setDefaultPreset(_ id: UUID?) {
        defaultPresetID = id
        RetouchPresetStore.defaultID = id
    }

    private func savePresets() {
        do {
            try RetouchPresetStore.save(presets)
        } catch {
            alert = AlertInfo(title: "保存修图预设失败", message: error.localizedDescription)
        }
    }

    // MARK: - 对话改图

    /// 摄影师对当前照片说一句话：调色立即生效，去除和重画进后台队列，完成后回写到对话里
    func sendChat(_ text: String) {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, let id = selectedPhotoID, let folder = folderURL, !chattingPhotoIDs.contains(id) else { return }
        let history = photos[id]?.chat ?? []
        appendChat(id, ChatMessage(role: .user, text: instruction))
        scheduleSave()
        chattingPhotoIDs.insert(id)
        Task {
            defer { chattingPhotoIDs.remove(id) }
            guard let client = await makeVisionClient(model: AppSettings.chatModel, purpose: .chat) else {
                appendChat(id, ChatMessage(role: .assistant, text: "看图模型的设置有问题，没有执行。", isError: true))
                return
            }
            do {
                guard let photo = photos[id] else { return }
                let preview = try await Task.detached { try Self.chatPreview(photo, folder: folder) }.value
                let editor = ChatEditor(client: client)
                let plan = try await editor.plan(
                    image: preview, edit: photo.edit ?? .neutral, history: history, instruction: instruction, note: photo.retouchNote
                )
                // 去除和重画先校正位置，确认不到的不执行
                let faces = photo.analysis?.faces.map(\.box) ?? []
                var targets: [ChatEditor.Target] = [], missing: [String] = []
                for target in plan.remove + plan.redraw {
                    if let box = try await editor.resolve(target, in: preview, faces: faces) {
                        targets.append(ChatEditor.Target(name: target.name, box: box, prompt: target.prompt, isFace: target.isFace))
                    } else {
                        missing.append(target.name)
                    }
                }
                // 等待期间换了文件夹或照片被移除：丢弃结果
                guard folderURL == folder, photos[id] != nil else { return }
                let aspect = CGFloat(preview.width) / CGFloat(preview.height)
                applyChatPlan(plan, targets: targets, missing: missing, photoID: id, instruction: instruction, imageAspect: aspect)
            } catch {
                appendChat(id, ChatMessage(role: .assistant, text: "没能完成：\(error.localizedDescription)", isError: true))
            }
            scheduleSave()
        }
    }

    /// 给模型看的当前效果：缩小的预览叠上去杂物和调色
    private nonisolated static func chatPreview(_ photo: Photo, folder: URL) throws -> CGImage {
        try preview(photo, edit: photo.edit, folder: folder, maxPixel: 1280)
    }

    private nonisolated static func preview(_ photo: Photo, edit: EditSettings?, folder: URL, maxPixel: Int) throws -> CGImage {
        guard let image = ImageLoader.image(at: photo.editURL, maxPixel: maxPixel),
              let rendered = try PhotoRenderer.render(
                  image, edit: edit, faces: photo.analysis?.faces ?? [], patches: photo.cleanups ?? [], folder: folder
              )
        else { throw AnalyzerError.unreadable(photo.editURL) }
        return rendered
    }

    private func applyChatPlan(
        _ plan: ChatEditor.Plan, targets: [ChatEditor.Target], missing: [String],
        photoID id: String, instruction: String, imageAspect aspect: CGFloat
    ) {
        if !plan.adjust.isEmpty {
            // 在最新的参数上改，期间摄影师手动拖过的滑块不被覆盖
            let edit = ChatEditor.applying(plan.adjust, to: photos[id]?.edit ?? .neutral)
            recordUndo(.edit, ids: [id], label: "对话改图：\(instruction.prefix(10))")
            photos[id]?.edit = edit == .neutral ? nil : edit
        }
        let pixelSize = photos[id].flatMap { ImageLoader.orientedPixelSize(at: $0.editURL) }
        var skipped: [String] = []
        for target in targets {
            let strokes = DistractionLocator.strokes(covering: target.box, imageAspect: aspect)
            if target.prompt != nil, let pixelSize {
                let crop = CleanupEngine.cropRect(for: strokes, imageSize: pixelSize)
                if max(crop.width, crop.height) / Double(CleanupEngine.uploadMaxPixel) > ChatEditor.maxRedrawUpscale {
                    skipped.append(target.name)
                    continue
                }
            }
            cleanupJobs.append(CleanupJob(
                photoID: id,
                strokes: strokes,
                itemName: target.name,
                isLarge: false,
                prompt: target.prompt.map(ChatEditor.redrawPrompt),
                fromChat: true
            ))
        }
        pumpCleanupQueue()
        appendChat(id, ChatMessage(role: .assistant, text: plan.reply))
        if !missing.isEmpty {
            appendChat(id, ChatMessage(
                role: .assistant,
                text: "放大确认时没找到「\(missing.joined(separator: "」「"))」，没有执行。可以说得更具体些，比如位置和颜色。",
                isError: true
            ))
        }
        if !skipped.isEmpty {
            appendChat(id, ChatMessage(
                role: .assistant,
                text: "「\(skipped.joined(separator: "」「"))」范围太大，重画后细节会明显变糊，没有执行。可以换成整体调色，或说得更具体一些缩小范围。",
                isError: true
            ))
        }
    }

    private func appendChat(_ photoID: String, _ message: ChatMessage) {
        // 先读后写，避免 @Observable 独占访问冲突
        let messages = (photos[photoID]?.chat ?? []) + [message]
        photos[photoID]?.chat = messages
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
        if gridMode {
            gridSelection = selectedPhotoID.map { [$0] } ?? []
            inspectorMode = .culling
        }
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

extension AppModel.CleanupJob {
    var undoLabel: String {
        guard let itemName else { return "去杂物" }
        return prompt == nil ? "去掉\(itemName)" : "重画\(itemName)"
    }
}

// MARK: - 多图合成

/// 合成进行中的状态，不保存：关掉 App 或换文件夹就丢弃
struct CompositeSession {
    enum Stage { case selecting, placing }

    let targetID: String
    let sourceID: String
    var stage: Stage = .selecting
    /// 来源照片的分割结果和用于分割的预览图（长边 2048）
    var segmentation: Compositor.Segmentation?
    /// 选中的蒙版，与分割预览同尺寸
    var mask: CGImage?
    var isPerson = false
    /// 蒙版染色后叠在来源照片上的提示层
    var maskOverlay: CGImage?
    /// 画笔修正：true 补选，false 擦除，nil 未在修正
    var refineAdd: Bool?
    /// 选中部分的包围框（来源归一化坐标）和带透明度的小图，拖放时显示
    var sourceBox: CGRect?
    var subjectPreview: CGImage?
    var placement: Compositor.Placement?
    /// 连拍自动对齐的初始放置，「重新对齐」时恢复
    var alignedPlacement: Compositor.Placement?
    var blendWithAI = false
    var status: String?
}

extension AppModel {
    /// 当前照片可选的来源：同一组连拍排在前面，其余按拍摄时间
    var compositeSourceCandidates: [Photo] {
        guard let target = selectedPhoto else { return [] }
        let groupIDs = Set(selectedGroup?.photoIDs ?? [])
        return photos.values
            .filter { $0.id != target.id }
            .sorted { a, b in
                let ga = groupIDs.contains(a.id), gb = groupIDs.contains(b.id)
                if ga != gb { return ga }
                return (a.captureDate ?? .distantPast, a.id) < (b.captureDate ?? .distantPast, b.id)
            }
    }

    var isCompositing: Bool { composite != nil }

    /// 合成进行中大图显示哪张：选取阶段显示来源，放置阶段显示当前照片
    var compositeShownPhoto: Photo? {
        guard let composite else { return nil }
        return photos[composite.stage == .selecting ? composite.sourceID : composite.targetID]
    }

    func beginComposite(sourceID: String) {
        guard let target = selectedPhotoID, let source = photos[sourceID] else { return }
        brushMode = false
        strokes = []
        zoom.pixelRatio = nil
        composite = CompositeSession(targetID: target, sourceID: sourceID, status: "正在识别来源照片里的主体…")
        let url = source.editURL
        Task {
            do {
                let segmentation = try await Task.detached {
                    guard let image = ImageLoader.image(at: url, maxPixel: 2048) else { throw Compositor.CompositeError.unreadable }
                    return try Compositor.segment(image)
                }.value
                guard composite?.sourceID == sourceID else { return }
                composite?.segmentation = segmentation
                composite?.status = "点一下要拿过来的人或东西"
            } catch {
                composite?.status = "识别失败：\(error.localizedDescription)"
            }
        }
    }

    /// 在来源照片上点一下选中主体
    func compositeTap(at point: CGPoint) {
        guard let segmentation = composite?.segmentation else { return }
        do {
            let selection = try Compositor.select(at: point, in: segmentation)
            composite?.isPerson = selection.isPerson
            setCompositeMask(selection.mask)
            composite?.status = selection.isPerson ? "已选中这个人。不准的地方可以用画笔补选或擦除" : "已选中。不准的地方可以用画笔补选或擦除"
        } catch {
            composite?.status = error.localizedDescription
        }
    }

    /// 画笔修正：切换补选 / 擦除，再点一次同一个退出
    func toggleCompositeRefine(add: Bool) {
        guard composite != nil else { return }
        composite?.refineAdd = composite?.refineAdd == add ? nil : add
        brushMode = composite?.refineAdd != nil
        strokes = []
    }

    /// 一笔画完立即作用到蒙版上；没有选中时补选就是从空白开始画
    func applyCompositeStroke() {
        guard let session = composite, let add = session.refineAdd, !strokes.isEmpty,
              let size = session.segmentation.map({ CGSize(width: $0.image.width, height: $0.image.height) })
        else { return }
        let base = session.mask ?? Self.emptyMask(size)
        if let refined = base.flatMap({ Compositor.refine($0, strokes: strokes, add: add) }) {
            setCompositeMask(refined)
        }
        strokes = []
    }

    private static func emptyMask(_ size: CGSize) -> CGImage? {
        let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: Int(size.width),
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
        return context?.makeImage()
    }

    private func setCompositeMask(_ mask: CGImage) {
        composite?.mask = mask
        let overlay = CIImage(color: CIColor(red: 0.2, green: 0.55, blue: 1, alpha: 0.45))
            .cropped(to: CGRect(x: 0, y: 0, width: mask.width, height: mask.height))
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: CIImage(cgImage: mask)])
        composite?.maskOverlay = PhotoRenderer.context.createCGImage(overlay, from: overlay.extent, format: .RGBA8, colorSpace: PhotoRenderer.sRGB)
    }

    /// 选好了：算出初始放置。同一组连拍或前后一分钟内的照片先尝试自动对齐，失败就放在画面中央
    func confirmCompositeSelection() {
        guard var session = composite, let mask = session.mask, let segmentation = session.segmentation,
              let box = Compositor.boundingBox(of: mask), let target = photos[session.targetID], let source = photos[session.sourceID]
        else {
            composite?.status = "还没有选中任何东西"
            return
        }
        let isBurst = selectedGroup?.photoIDs.contains(source.id) == true
            || abs((source.captureDate ?? .distantPast).timeIntervalSince(target.captureDate ?? .distantFuture)) < 60
        brushMode = false
        strokes = []
        session.refineAdd = nil
        session.status = isBurst ? "正在和当前照片对齐…" : nil
        composite = session
        let targetURL = target.editURL, sourceSize = CGSize(width: segmentation.image.width, height: segmentation.image.height)
        let sourceImage = segmentation.image, isPerson = session.isPerson
        Task {
            let result = await Task.detached { () -> (CGImage, CGRect, Compositor.Placement?) in
                var mask = mask, box = box
                var placement: Compositor.Placement?
                if isBurst, let targetImage = ImageLoader.image(at: targetURL, maxPixel: 2048),
                   let map = Compositor.alignment(source: sourceImage, target: targetImage, focus: box) {
                    // 连拍换人：把当前照片里对应的人也盖住；认不出时把来源主体外扩一圈
                    let center = CGPoint(x: box.midX, y: box.midY), mapped = map(center)
                    let offset = CGPoint(x: mapped.x - center.x, y: mapped.y - center.y)
                    let covered = (try? Compositor.select(at: mapped, in: Compositor.segment(targetImage), peopleOnly: isPerson))
                        .flatMap { Compositor.coverMask(sourceMask: mask, targetMask: $0.mask, offset: offset) }
                    if let merged = covered ?? Compositor.expandedMask(mask), let mergedBox = Compositor.boundingBox(of: merged) {
                        mask = merged
                        box = mergedBox
                    }
                    let corners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY)].map(map)
                    placement = Compositor.Placement(
                        rect: CGRect(x: corners[0].x, y: corners[0].y, width: corners[1].x - corners[0].x, height: corners[1].y - corners[0].y),
                        warp: map
                    )
                }
                return (mask, box, placement)
            }.value
            guard composite?.sourceID == source.id else { return }
            let (finalMask, finalBox, aligned) = result
            composite?.mask = finalMask
            composite?.sourceBox = finalBox
            composite?.subjectPreview = Self.subjectPreview(sourceImage, mask: finalMask, box: finalBox)
            let targetSize = ImageLoader.orientedPixelSize(at: targetURL) ?? sourceSize
            let placement = aligned ?? Compositor.Placement(rect: Compositor.defaultRect(
                sourceBox: finalBox, sourceSize: ImageLoader.orientedPixelSize(at: source.editURL) ?? sourceSize,
                targetSize: targetSize, center: CGPoint(x: 0.5, y: 0.6)
            ))
            composite?.placement = placement
            composite?.alignedPlacement = aligned
            composite?.stage = .placing
            composite?.status = aligned != nil
                ? "已和连拍自动对齐。确认没问题就点「完成合成」，也可以拖动微调"
                : (isBurst ? "没能自动对齐，请拖动到合适位置；拖右下角调大小" : "拖动到合适位置；拖右下角调大小")
        }
    }

    private static func subjectPreview(_ image: CGImage, mask: CGImage, box: CGRect) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let crop = CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
        let cut = CIImage(cgImage: image).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: CIImage(cgImage: mask),
        ]).cropped(to: crop)
        return PhotoRenderer.context.createCGImage(cut, from: crop, format: .RGBA8, colorSpace: PhotoRenderer.sRGB)
    }

    /// 拖动或缩放：手动调整后不再按连拍对齐的透视变换贴
    func moveCompositePlacement(to rect: CGRect) {
        composite?.placement?.rect = rect
        composite?.placement?.warp = nil
    }

    func flipCompositePlacement() {
        composite?.placement?.flipped.toggle()
        composite?.placement?.warp = nil
    }

    func realignComposite() {
        guard let aligned = composite?.alignedPlacement else { return }
        composite?.placement = aligned
    }

    func cancelComposite() {
        if let target = composite?.targetID, let group = groups.first(where: { $0.photoIDs.contains(target) }) {
            selectGroup(group.id, photoID: target)
        }
        composite = nil
        brushMode = false
        strokes = []
    }

    /// 在全尺寸上合成并作为一块修补贴到当前照片；勾选了 AI 融合就再排一个重画任务
    func finishComposite() {
        guard let session = composite, let placement = session.placement, let mask = session.mask, let box = session.sourceBox,
              let target = photos[session.targetID], let source = photos[session.sourceID], let folder = folderURL
        else { return }
        composite?.status = "正在合成…"
        let blend = session.blendWithAI
        Task {
            do {
                let patch = try await Task.detached {
                    guard let sourceFull = PhotoRenderer.fullResolution(of: source),
                          let targetFull = PhotoRenderer.fullResolution(of: target)
                    else { throw Compositor.CompositeError.unreadable }
                    // 两边都先叠上各自的去杂物结果，拿过来的东西和底图都是干净的
                    let sourceBase = try PhotoRenderer.composite(sourceFull, patches: source.cleanups ?? [], folder: folder)
                    let targetBase = try PhotoRenderer.composite(targetFull, patches: target.cleanups ?? [], folder: folder)
                    return try Compositor.bake(source: sourceBase, mask: mask, sourceBox: box, target: targetBase, placement: placement, folder: folder)
                }.value
                guard folderURL == folder, photos[target.id] != nil else { return }
                let patches = (photos[target.id]?.cleanups ?? []) + [patch]
                recordUndo(.cleanups, ids: [target.id], label: "合成：从 \(source.fileName) 取")
                photos[target.id]?.cleanups = patches
                if blend, let size = ImageLoader.orientedPixelSize(at: target.editURL) {
                    let r = patch.rect
                    cleanupJobs.append(CleanupJob(
                        photoID: target.id,
                        strokes: DistractionLocator.strokes(covering: r, imageAspect: size.width / size.height),
                        itemName: "合成主体（融合边缘和影子）",
                        isLarge: false,
                        prompt: Compositor.blendPrompt
                    ))
                    pumpCleanupQueue()
                }
                scheduleSave()
                cancelComposite()
            } catch {
                composite?.status = "合成失败：\(error.localizedDescription)"
            }
        }
    }
}

// MARK: - AI 用量

extension AppModel {
    /// 本地日志（哪场、做什么）与 Magpie 记录（实际模型、token、折算价）对账
    func usageReport(since: Date, until: Date = .distantFuture, shoot: String? = nil) async throws -> (UsageReport, [MagpieUsage.Quota]) {
        guard let baseURL = URL(string: AppSettings.baseURL.trimmingCharacters(in: .whitespaces)) else {
            throw VisionChatClient.ClientError.emptyResponse
        }
        let entries = UsageLog.shared.entries(since: since).filter { $0.start <= until && (shoot == nil || $0.shoot == shoot) }
        async let rows = MagpieUsage.rows(baseURL: baseURL)
        async let quotas = MagpieUsage.quotas(baseURL: baseURL)
        return (UsageReport.build(entries: entries, rows: try await rows), (try? await quotas) ?? [])
    }
}

enum InspectorMode: String {
    case culling, editing
}

/// 修图模式下右侧工具栏的工具
enum EditTool: String, CaseIterable, Identifiable {
    case adjust, cleanup, composite, chat, log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .adjust: "调色"
        case .cleanup: "去杂物"
        case .composite: "合成"
        case .chat: "对话改图"
        case .log: "初修记录"
        }
    }

    var symbol: String {
        switch self {
        case .adjust: "slider.horizontal.3"
        case .cleanup: "eraser"
        case .composite: "square.on.square.dashed"
        case .chat: "bubble.left.and.text.bubble.right"
        case .log: "list.bullet.clipboard"
        }
    }
}
