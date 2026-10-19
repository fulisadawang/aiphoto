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
                Button("清除涂抹") { model.strokes = [] }
                    .disabled(model.strokes.isEmpty)
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)

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
                        .disabled(model.isBusy)
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
