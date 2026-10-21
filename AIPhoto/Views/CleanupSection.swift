import SwiftUI

struct CleanupSection: View {
    @Environment(AppModel.self) private var model
    let photo: Photo

    var body: some View {
        Section("去杂物") {
            HStack {
                Toggle(isOn: Binding(get: { model.brushMode }, set: { _ in model.toggleBrush() })) {
                    Label("画笔 B", systemImage: "paintbrush.pointed")
                }
                .toggleStyle(.button)
                Button("消除 ↩") { model.runCleanup() }
                    .disabled(model.strokes.isEmpty)
                Button("整组消除 ⇧↩") { model.runCleanup(wholeGroup: true) }
                    .disabled(model.strokes.isEmpty)
                    .help("同组连拍里未淘汰的照片，在同一位置一起消除")
                Button("清除") { model.strokes = [] }
                    .disabled(model.strokes.isEmpty)
            }
            .buttonStyle(.bordered)

            Button {
                model.removeDistractions()
            } label: {
                Label("一键去掉干扰物", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .disabled(model.isCleaning(photo.id))
            .help("AI 找出推车、杂物、电线、路人等背景杂物并自动去掉；孩子手里的东西不动")

            if model.isCleaning(photo.id) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(model.locatingPhotoIDs.contains(photo.id) ? "正在识别干扰物位置…" : "这张正在后台去杂物，可以继续看别的照片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.brushMode {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("画笔大小（[ ] 调整）")
                        Spacer()
                        Text(String(format: "%.1f%%", model.brushSize * 100))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { model.brushSize }, set: { model.brushSize = $0 }), in: 0.005...0.2)
                        .controlSize(.small)
                }
            }

            if let patches = photo.cleanups, !patches.isEmpty {
                let localCount = patches.filter { $0.local == true }.count
                VStack(alignment: .leading, spacing: 6) {
                    Text(localCount > 0 ? "已消除 \(patches.count) 处（本机 \(localCount) 处）" : "已消除 \(patches.count) 处")
                    HStack {
                        if patches.last?.local == true, patches.last?.strokes != nil {
                            Button("用 AI 重画上一处") { model.redoLastCleanupWithAI() }
                                .help("本机补得不满意时，用同样的涂抹交给 AI 重新去除（会产生出图费用）")
                        }
                        Button("撤销上一次") { model.undoCleanup() }
                    }
                    .controlSize(.small)
                }
            }

            LocalModelRow()

            if let distractions = photo.ai?.distractions, !distractions.isEmpty {
                Text("AI 发现的干扰物：\(distractions.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if InpaintService.current == .none {
                Text("还没有配置去杂物服务，请在「小宇专属 › 设置…」里配置。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// 本机去杂物模型的状态：没下载时说明好处并提供下载，下载中显示进度
struct LocalModelRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.lamaState {
        case .installed:
            Label("小块杂物在本机免费去除（不到画面 0.3%），大的仍用 AI", systemImage: "cpu")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notInstalled:
            VStack(alignment: .leading, spacing: 6) {
                Text("下载本机模型后，电线、小杂物这类小块在本机去除：不花钱、不上传、不到 1 秒。路人、推车这类大的仍用 AI。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    model.installLaMa()
                } label: {
                    Label("下载本机模型（\(ByteCountFormatter.string(fromByteCount: LaMaModel.byteCount, countStyle: .file))）", systemImage: "arrow.down.circle")
                }
                .controlSize(.small)
            }
        case .downloading(let value):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: value).controlSize(.small)
                Text(String(format: "正在下载本机模型 %.0f%%", value * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在准备本机模型…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text("本机模型下载失败：\(message)").font(.caption).foregroundStyle(.orange)
                Button("重试") { model.installLaMa() }.controlSize(.small)
            }
        }
    }
}
