import AppKit
import Combine
import Sparkle
import SwiftUI

/// 接收从 Dock 图标或 `open -a` 传入的文件夹
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 冷启动时文件夹可能先于窗口到达，先暂存
    private var pendingFolder: URL?

    /// 主窗口被关掉后重新打开它；由窗口内容出现时设置
    var reopenMain: (() -> Void)?

    var openFolder: ((URL) -> Void)? {
        didSet {
            guard let folder = pendingFolder, let openFolder else { return }
            pendingFolder = nil
            openFolder(folder)
        }
    }

    /// 点左上角关闭只关窗口，App 留在 Dock 里，选片进度和撤销记录都还在
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 窗口关掉后点 Dock 图标，把主窗口重新打开
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { reopenMain?() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let folder = urls.first(where: \.hasDirectoryPath) else { return }
        // 窗口关着时把文件夹拖到 Dock 图标上：先把窗口打开
        reopenMain?()
        if let openFolder {
            openFolder(folder)
        } else {
            pendingFolder = folder
        }
    }
}

@main
struct AIPhotoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()
    private let updaterController: SPUStandardUpdaterController

    init() {
        AppSettings.registerDefaults()
        InpaintService.registerDefaults()
        ModelCatalog.registerDefaults()
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var body: some Scene {
        // 只有一份选片数据，用单窗口；用 WindowGroup 时从访达或 open 命令打开文件夹会多开窗口
        Window("小宇专属", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear { delegate.openFolder = { [model] in model.requestOpen($0) } }
                .background(ReopenBridge(delegate: delegate))
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("打开照片文件夹…") { model.openFolder() }
                    .keyboardShortcut("o")
                    .disabled(model.isBusy)
            }
            // 替换系统的撤销菜单：撤销的是选片和修图操作，菜单上写明撤销的是什么
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoLabel.map { "撤销「\($0)」" } ?? "撤销") { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(model.undoLabel == nil)
                Button(model.redoLabel.map { "重做「\($0)」" } ?? "重做") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(model.redoLabel == nil)
            }
            CommandMenu("选片") {
                // 按处理方式显示（第 17 节）：AI 选片和一键初修只在 AI 选片方式下，一键去杂物只在自己选片方式下
                Group {
                    if model.shootMode == .ai {
                        Button("AI 选片（只处理还没评估的组）") { model.runAI(all: false) }
                            .keyboardShortcut("r")
                        Button("全部重新 AI 选片") { model.runAI(all: true) }
                        Divider()
                    }
                    if model.shootMode != .editOnly {
                        Button("把选片结果写入 RAW 的 XMP 星级") { model.writeXMP() }
                            .keyboardShortcut("e", modifiers: [.command, .shift])
                        Button("拷贝已选照片到文件夹…") { model.copyPicked() }
                        Divider()
                    }
                    if model.shootMode == .ai {
                        Button("一键初修已选照片…") { model.showRetouchStart = true }
                            .keyboardShortcut("r", modifiers: [.command, .shift])
                    }
                    if model.shootMode == .manual {
                        Button("一键去杂物已选照片…") { model.showCleanupStart = true }
                            .keyboardShortcut("r", modifiers: [.command, .shift])
                    }
                    if model.shootMode != .editOnly {
                        Button(model.lastBatchOnlyCleanup ? "查看去杂物总结" : "查看初修总结") { model.showRetouchSummary = true }
                        Divider()
                        Button("已选照片自动调色（跳过已调过的）") { model.autoAdjustAllPicked() }
                    }
                    Button(model.shootMode == .editOnly ? "导出全部成片（JPG）…" : "导出已选成片（JPG）…") { model.exportFinishedJPEGs() }
                        .keyboardShortcut("e")
                    if model.shootMode != .editOnly {
                        Divider()
                        Button("按当前设置重新分组") { model.regroup() }
                    }
                }
                .disabled(model.groups.isEmpty || model.isBusy)
                Button("取消 AI 选片") { model.cancelBusy() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.canCancelBusy)
                Divider()
                Button("从修图样片学习风格…") { model.learnStyle() }
                    .disabled(model.isBusy)
                Button("管理修图预设…") { model.showPresetManager = true }
                Button("AI 用量…") { model.showUsage = true }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// 把 SwiftUI 的 openWindow 交给 AppDelegate，窗口关掉后点 Dock 图标能重新打开
private struct ReopenBridge: View {
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate

    var body: some View {
        Color.clear.onAppear { delegate.reopenMain = { openWindow(id: "main") } }
    }
}

/// 「检查更新…」菜单项；更新检查进行中时禁用
private struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("检查更新…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
    }
}
