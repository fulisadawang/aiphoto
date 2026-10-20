import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showInspector = true
    @FocusState private var viewerFocused: Bool

    /// 对话改图的输入框有焦点时，按键交给文本框，不触发选片快捷键（文本框编辑时第一响应者是字段编辑器 NSTextView）
    private var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSTextView || model.isCompositing }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            GroupSidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 360)
        } detail: {
            VStack(spacing: 0) {
                if model.folderURL == nil {
                    WelcomeView()
                } else if model.groups.isEmpty {
                    ProgressView(model.statusText.isEmpty ? "准备中…" : model.statusText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.gridMode {
                    GridView()
                        .onTapGesture { viewerFocused = true }
                } else if let photo = model.selectedPhoto {
                    // 合成选取阶段大图显示来源照片
                    PhotoViewer(photo: model.compositeShownPhoto ?? photo)
                        .onTapGesture { viewerFocused = true }
                    Divider()
                    Filmstrip(photos: model.selectedPhotos)
                        .frame(height: 118)
                } else {
                    ContentUnavailableView("这个筛选条件下没有照片", systemImage: "photo.on.rectangle")
                }
                Divider()
                StatusBar()
            }
            .focusable()
            .focusEffectDisabled()
            .focused($viewerFocused)
        }
        .inspector(isPresented: $showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 320, ideal: 350, max: 420)
        }
        .onKeyPress(.leftArrow) { if isEditingText { return .ignored }; model.gridMode ? model.gridStep(by: -1) : model.previousPhoto(); return .handled }
        .onKeyPress(.rightArrow) { if isEditingText { return .ignored }; model.gridMode ? model.gridStep(by: 1) : model.nextPhoto(); return .handled }
        .onKeyPress(.upArrow) { if isEditingText { return .ignored }; model.gridMode ? model.gridStepGroup(by: -1) : model.previousGroup(); return .handled }
        .onKeyPress(.downArrow) { if isEditingText { return .ignored }; model.gridMode ? model.gridStepGroup(by: 1) : model.nextGroup(); return .handled }
        .onKeyPress(.space) {
            guard !model.brushMode, !isEditingText else { return .ignored }
            model.zoomToFocus()
            return .handled
        }
        .onKeyPress(keys: [.return]) { press in
            if isEditingText { return .ignored }
            if model.gridMode, let id = model.selectedPhotoID {
                model.openInViewer(id)
                return .handled
            }
            guard model.brushMode, !model.strokes.isEmpty else { return .ignored }
            model.runCleanup(wholeGroup: press.modifiers.contains(.shift))
            return .handled
        }
        .onKeyPress(.escape) {
            if model.isCompositing {
                model.cancelComposite()
                return .handled
            }
            guard model.brushMode, !isEditingText else { return .ignored }
            if model.strokes.isEmpty { model.toggleBrush() } else { model.strokes = [] }
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "pxufabzkjgPXUFABZKJG012345\\[]")) { press in
            if isEditingText { return .ignored }
            model.handleKey(press.characters)
            return .handled
        }
        .onAppear { viewerFocused = true }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: \.hasDirectoryPath), !model.isBusy else { return false }
            model.load(folder)
            return true
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.openFolder()
                } label: {
                    Label("打开文件夹", systemImage: "folder")
                }
                .disabled(model.isBusy)

                Menu {
                    Button("AI 选片（只处理还没评估的组）") { model.runAI(all: false) }
                    Button("全部重新 AI 选片") { model.runAI(all: true) }
                } label: {
                    Label("AI 选片", systemImage: "sparkles")
                } primaryAction: {
                    model.runAI(all: false)
                }
                .disabled(model.groups.isEmpty || model.isBusy)
                .help("把每组候选照片发给 AI 选片模型，挑出最值得交付的")

                Toggle(isOn: Binding(get: { model.gridMode }, set: { _ in model.toggleGrid() })) {
                    Label("网格总览", systemImage: "square.grid.3x3")
                }
                .help("G：一屏看完整场照片，可框选批量选用 / 淘汰")
                .disabled(model.groups.isEmpty)

                Button {
                    model.showRetouchStart = true
                } label: {
                    Label("一键初修", systemImage: "wand.and.stars.inverse")
                }
                .disabled(model.pickedCount == 0 || model.retouchProgress != nil)
                .help("对所有已选照片全自动初修：调色、皮肤轻度柔化、去背景杂物，完成后给出总结")

                Menu {
                    Button("把选片结果写入 RAW 的 XMP 星级") { model.writeXMP() }
                    Button("拷贝已选照片到文件夹…") { model.copyPicked() }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(model.groups.isEmpty || model.isBusy)

                Button {
                    showInspector.toggle()
                } label: {
                    Label("详情", systemImage: "sidebar.right")
                }
            }
        }
        .sheet(isPresented: $model.showRetouchStart) { RetouchStartSheet().environment(model) }
        .sheet(isPresented: $model.showPresetManager) { PresetManagerSheet().environment(model) }
        .sheet(isPresented: $model.showSavePreset) { SavePresetSheet().environment(model) }
        .sheet(isPresented: $model.showCompositePicker) { CompositeSourcePicker().environment(model) }
        .sheet(isPresented: $model.showUsage) { UsageView().environment(model) }
        .sheet(isPresented: $model.showRetouchSummary) { RetouchSummaryView().environment(model) }
        .alert(item: $model.alert) { info in
            Alert(title: Text(info.title), message: Text(info.message))
        }
        .navigationTitle(model.folderURL?.lastPathComponent ?? "小宇专属")
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if model.isBusy {
                ProgressView(value: model.progress)
                    .frame(width: 160)
                Text(model.statusText)
                    .monospacedDigit()
                if model.canCancelBusy {
                    Button {
                        model.cancelBusy()
                    } label: {
                        Label("取消", systemImage: "xmark.circle.fill")
                    }
                    .controlSize(.small)
                    .help("停止 AI 选片，已完成的结果保留（⌘.）")
                }
            } else if !model.groups.isEmpty {
                Text("← → 切换照片　↑ ↓ 切换组　P 选用　X 淘汰　U 取消　1-5 星级　空格 放大人脸　F 人脸框　A 自动调色　\\ 修复前后对比　B 画笔去杂物　Z 缩放　K 合焦高亮　J 过曝提示　G 网格总览")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = model.retouchProgress {
                HStack(spacing: 6) {
                    ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
                        .frame(width: 100)
                    Text("初修 \(progress.done)/\(progress.total)")
                        .monospacedDigit()
                }
            }
            if !model.cleanupJobs.isEmpty {
                let running = model.cleanupJobs.filter(\.isRunning).count
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("去杂物：进行中 \(running) · 排队 \(model.cleanupJobs.count - running)")
                }
            }
            if !model.photos.isEmpty {
                Text("共 \(model.photos.count) 张 · \(model.groups.count) 组 · AI 已评 \(model.aiReviewedGroupCount) 组 · 已选 \(model.pickedCount) · 淘汰 \(model.rejectedCount)")
                    .monospacedDigit()
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("打开一场拍摄的照片文件夹")
                .font(.title2.bold())
            VStack(alignment: .leading, spacing: 8) {
                Label("自动配对 RAW + JPG，按连拍归组", systemImage: "rectangle.stack")
                Label("本地检测模糊、闭眼、曝光问题，每组预选一张", systemImage: "eye")
                Label("AI 按亲子纪实标准在组内择优，并给出理由", systemImage: "sparkles")
                Label("结果写入 XMP 星级，或拷贝到新文件夹", systemImage: "square.and.arrow.up")
            }
            .foregroundStyle(.secondary)
            Button("打开文件夹…") { model.openFolder() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
