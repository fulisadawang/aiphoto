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
    var zoomed = false
    var showFaces = false
    /// 按住对比：显示未调色、未去杂物的原图
    var showOriginal = false

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
        let client: VisionChatClient
        do {
            let text = AppSettings.baseURL.trimmingCharacters(in: .whitespaces)
            guard let baseURL = URL(string: text), baseURL.scheme?.hasPrefix("http") == true else {
                alert = AlertInfo(title: "选片模型地址无效", message: "请在「AI选片 › 设置…」里检查接口地址：\(text)")
                return
            }
            client = VisionChatClient(
                baseURL: baseURL,
                apiKey: try KeychainStore.load(account: AppSettings.keychainAccount) ?? "",
                model: AppSettings.model
            )
        } catch {
            alert = AlertInfo(title: "读取 API 密钥失败", message: error.localizedDescription)
            return
        }
        perform("AI 选片中…") { try await self.rankWithAI(client: client, all: all) }
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
        photos[id]?.decision = decision
        photos[id]?.decidedByUser = true
        scheduleSave()
    }

    func setRating(_ rating: Int) {
        guard let id = selectedPhotoID else { return }
        photos[id]?.rating = rating
        if rating > 0 { photos[id]?.decision = .pick }
        photos[id]?.decidedByUser = true
        scheduleSave()
    }

    func handleKey(_ characters: String) {
        switch characters.lowercased() {
        case "p": setDecision(.pick)
        case "x": setDecision(.reject)
        case "u": setDecision(.none)
        case "f": showFaces.toggle()
        case "\\": showOriginal.toggle()
        case "a": autoAdjustSelected()
        case "b": toggleBrush()
        case "[": brushSize = max(0.005, brushSize / 1.25)
        case "]": brushSize = min(0.2, brushSize * 1.25)
        case "1", "2", "3", "4", "5": setRating(Int(characters) ?? 0)
        case "0": setRating(0)
        default: break
        }
    }

    // MARK: - 调色

    func updateEdit(_ edit: EditSettings) {
        guard let id = selectedPhotoID else { return }
        photos[id]?.edit = edit == .neutral ? nil : edit
        scheduleSave()
    }

    func autoAdjustSelected() {
        guard let photo = selectedPhoto else { return }
        perform("自动调色中…") {
            let url = photo.editURL, analysis = photo.analysis
            let edit = try await Task.detached { try AutoAdjuster.compute(url: url, analysis: analysis) }.value
            self.photos[photo.id]?.edit = edit
            self.showOriginal = false
            self.scheduleSave()
        }
    }

    /// 同一组连拍光线一致，直接复用当前照片的参数，保证整组色调统一
    func syncEditToGroup() {
        guard let edit = selectedPhoto?.edit else { return }
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
        zoomed = false
        if !brushMode { strokes = [] }
    }

    func beginStroke(at point: CGPoint) {
        strokes.append(BrushStroke(points: [point], radius: brushSize))
    }

    func extendStroke(to point: CGPoint) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].points.append(point)
    }

    func runCleanup() {
        guard let photo = selectedPhoto, let folder = folderURL else { return }
        guard !strokes.isEmpty else {
            alert = AlertInfo(title: "还没有涂抹", message: "按 B 进入画笔模式，在大图上涂抹要去掉的物体，再点「消除」。")
            return
        }
        let provider: InpaintProvider
        do {
            provider = try InpaintService.makeProvider()
        } catch {
            alert = AlertInfo(title: "去杂物服务不可用", message: error.localizedDescription)
            return
        }
        let strokes = self.strokes
        perform("正在消除（云端补全，通常需要 20～60 秒）…") {
            let patch = try await CleanupEngine.run(photo: photo, strokes: strokes, folder: folder, provider: provider)
            // 先读后写：@Observable 属性在写入期间再读取同一属性会触发独占访问冲突而崩溃
            let patches = (self.photos[photo.id]?.cleanups ?? []) + [patch]
            self.photos[photo.id]?.cleanups = patches
            if self.selectedPhotoID == photo.id { self.strokes = [] }
            self.showOriginal = false
            self.scheduleSave()
        }
    }

    func undoCleanup() {
        guard let id = selectedPhotoID, let folder = folderURL,
              var patches = photos[id]?.cleanups, let last = patches.popLast()
        else { return }
        photos[id]?.cleanups = patches.isEmpty ? nil : patches
        scheduleSave()
        do {
            try FileManager.default.removeItem(at: CleanupEngine.patchURL(last.id, folder: folder))
        } catch {
            alert = AlertInfo(title: "已撤销，但修补文件没能删除", message: error.localizedDescription)
        }
    }

    // MARK: - 导航

    func selectGroup(_ id: Int?, photoID: String? = nil) {
        selectedGroupID = id
        zoomed = false
        strokes = []
        guard let group = selectedGroup else {
            selectedPhotoID = nil
            return
        }
        selectedPhotoID = photoID ?? representative(of: group)?.id
    }

    func selectPhoto(_ id: String) {
        selectedPhotoID = id
        zoomed = false
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
