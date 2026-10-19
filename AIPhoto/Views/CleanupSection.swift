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

            if let count = photo.cleanups?.count {
                HStack {
                    Text("已消除 \(count) 处")
                    Spacer()
                    Button("撤销上一次") { model.undoCleanup() }
                }
            }

            if let distractions = photo.ai?.distractions, !distractions.isEmpty {
                Text("AI 发现的干扰物：\(distractions.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if InpaintService.current == .none {
                Text("还没有配置去杂物服务，请在「AI选片 › 设置…」里配置。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
