import AppKit
import SwiftUI

/// 接收从 Dock 图标或 `open -a` 传入的文件夹
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 冷启动时文件夹可能先于窗口到达，先暂存
    private var pendingFolder: URL?

    var openFolder: ((URL) -> Void)? {
        didSet {
            guard let folder = pendingFolder, let openFolder else { return }
            pendingFolder = nil
            openFolder(folder)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let folder = urls.first(where: \.hasDirectoryPath) else { return }
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

    init() {
        AppSettings.registerDefaults()
        InpaintService.registerDefaults()
    }

    var body: some Scene {
        // 只有一份选片数据，用单窗口；用 WindowGroup 时从访达或 open 命令打开文件夹会多开窗口
        Window("AI 选片", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear { delegate.openFolder = { [model] in model.load($0) } }
        }
        .commands {
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
                Group {
                    Button("AI 选片（只处理还没评估的组）") { model.runAI(all: false) }
                        .keyboardShortcut("r")
                    Button("全部重新 AI 选片") { model.runAI(all: true) }
                    Divider()
                    Button("把选片结果写入 RAW 的 XMP 星级") { model.writeXMP() }
                        .keyboardShortcut("e", modifiers: [.command, .shift])
                    Button("拷贝已选照片到文件夹…") { model.copyPicked() }
                    Divider()
                    Button("一键初修已选照片…") { model.showRetouchStart = true }
                        .keyboardShortcut("r", modifiers: [.command, .shift])
                    Button("查看初修总结") { model.showRetouchSummary = true }
                    Divider()
                    Button("已选照片自动调色（跳过已调过的）") { model.autoAdjustAllPicked() }
                    Button("导出已选成片（JPG）…") { model.exportFinishedJPEGs() }
                        .keyboardShortcut("e")
                    Divider()
                    Divider()
                    Button("按当前设置重新分组") { model.regroup() }
                }
                .disabled(model.groups.isEmpty || model.isBusy)
                Button("从修图样片学习风格…") { model.learnStyle() }
                    .disabled(model.isBusy)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
