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
            model.requestOpen(folder)
            return true
        }
        .toolbar {
            // 每个按钮都显示「图标 + 中文」（第 17 节：只有图标时「AI 选片」和「一键初修」分不清）
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.openFolder()
                } label: {
                    Label("打开", systemImage: "folder")
                }
                .disabled(model.isBusy)
                .help("打开一场拍摄的照片文件夹")

                if model.folderURL != nil {
                    Menu {
                        ForEach(ShootMode.allCases) { mode in
                            Button {
                                model.switchMode(mode)
                            } label: {
                                if mode == model.shootMode { Image(systemName: "checkmark") }
                                Text(mode.title)
                            }
                        }
                    } label: {
                        // 带「方式：」前缀，和「AI 选片」按钮区分开（实测同名同图标时看起来像重复按钮）
                        Label("方式：\(model.shootMode.title)", systemImage: "rectangle.stack.badge.person.crop")
                    }
                    .disabled(model.isBusy)
                    .help("这批照片怎么处理；切换不会清掉已经标过的选用、淘汰")
                }

                if model.shootMode == .ai {
                    Menu {
                        Button("AI 选片（只处理还没评估的组）") { model.runAI(all: false) }
                        Button("全部重新 AI 选片") { model.runAI(all: true) }
                    } label: {
                        Label("AI 选片", systemImage: "checkmark.rectangle.stack")
                    } primaryAction: {
                        model.runAI(all: false)
                    }
                    .disabled(model.groups.isEmpty || model.isBusy)
                    .help("把每组候选照片发给 AI，挑出最值得交付的")

                    Button {
                        model.showRetouchStart = true
                    } label: {
                        Label("一键初修", systemImage: "paintpalette")
                    }
                    .disabled(model.pickedCount == 0 || model.retouchProgress != nil)
                    .help("对所有已选照片全自动初修：调色、皮肤轻度柔化、去背景杂物，完成后给出总结")
                }

                if model.shootMode == .manual {
                    Button {
                        model.showCleanupStart = true
                    } label: {
                        Label("一键去杂物", systemImage: "eraser")
                    }
                    .disabled(model.pickedCount == 0 || model.retouchProgress != nil)
                    .help("对所有已选照片去掉路人、垃圾、杂物；不调色、不磨皮")
                }

                if model.shootMode != .editOnly {
                    Toggle(isOn: Binding(get: { model.gridMode }, set: { _ in model.toggleGrid() })) {
                        Label("网格", systemImage: "square.grid.3x3")
                    }
                    .help("G：一屏看完整场照片，可框选批量选用 / 淘汰")
                    .disabled(model.groups.isEmpty)
                }

                Menu {
                    if model.shootMode == .editOnly {
                        Button("导出全部成片（JPG）…") { model.exportFinishedJPEGs() }
                    } else {
                        Button("导出已选成片（JPG）…") { model.exportFinishedJPEGs() }
                        Button("把选片结果写入 RAW 的 XMP 星级") { model.writeXMP() }
                        Button("拷贝已选照片到文件夹…") { model.copyPicked() }
                    }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(model.groups.isEmpty || model.isBusy)

                Button {
                    showInspector.toggle()
                } label: {
                    Label("详情", systemImage: "sidebar.right")
                }
                .help("显示或隐藏右侧面板")
            }
        }
        .labelStyle(.titleAndIcon)
        .sheet(isPresented: Binding(
            get: { model.pendingOpenFolder != nil },
            set: { if !$0 { model.pendingOpenFolder = nil } }
        )) {
            if let folder = model.pendingOpenFolder {
                ShootModeSheet(folder: folder, initial: model.pendingOpenMode).environment(model)
            }
        }
        .confirmationDialog("一键去杂物 \(model.pickedCount) 张已选照片", isPresented: $model.showCleanupStart) {
            Button("开始去杂物") { model.startBatchCleanup() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("AI 找出路人、垃圾、推车、电线等背景杂物并去掉；孩子手里的东西不动。不调色、不磨皮。全程在后台进行，每张约 30～60 秒，完成后给出总结。")
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
                Text(model.shootMode == .editOnly
                     ? "← → 切换照片　空格 放大人脸　F 人脸框　A 自动调色　\\ 修复前后对比　B 画笔去杂物　Z 缩放　K 合焦高亮　J 过曝提示"
                     : "← → 切换照片　↑ ↓ 切换组　P 选用　X 淘汰　U 取消　1-5 星级　空格 放大人脸　F 人脸框　A 自动调色　\\ 修复前后对比　B 画笔去杂物　Z 缩放　K 合焦高亮　J 过曝提示　G 网格总览")
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
