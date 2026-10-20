import SwiftUI

struct EditSection: View {
    @Environment(AppModel.self) private var model
    let photo: Photo

    var body: some View {
        let edit = photo.edit ?? .neutral
        Section("修图") {
            HStack {
                Button { model.autoAdjustSelected() } label: { Label("自动 A", systemImage: "wand.and.stars") }
                Button("重置") { model.updateEdit(.neutral, recordingUndo: "重置修图") }
                    .disabled(photo.edit == nil)
                Spacer()
                Toggle("对比 \\", isOn: Binding(get: { model.compareMode }, set: { model.compareMode = $0 }))
                    .toggleStyle(.button)
                    .help("修复前后对比：左边原图，右边修复后，拖动中间的分割线")
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)

            PresetMenu(photo: photo)

            Picker("风格", selection: Binding(
                get: { edit.styleID },
                set: { id in
                    var updated = photo.edit ?? .neutral
                    updated.styleID = id
                    model.updateEdit(updated, recordingUndo: "风格")
                }
            )) {
                Text("无").tag(UUID?.none)
                ForEach(model.styles) { Text($0.name).tag(Optional($0.id)) }
            }
            if model.styles.isEmpty {
                Text("还没有风格。用「选片 › 从修图样片学习风格…」学一个。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if edit.styleID != nil {
                slider("风格力度", value: edit.styleStrength, range: 0...1, format: "%.0f%%", scale: 100) { $0.styleStrength = $1 }
            }
            slider("曝光", value: edit.exposure, range: -2...2, format: "%+.2f EV") { $0.exposure = $1 }
            slider("色温", value: edit.temperature, range: 2500...11000, format: "%.0f K") { $0.temperature = $1 }
            slider("色调", value: edit.tint, range: -60...60, format: "%+.0f") { $0.tint = $1 }
            slider("高光", value: edit.highlights, range: -1...0, format: "%.2f") { $0.highlights = $1 }
            slider("阴影", value: edit.shadows, range: 0...1, format: "%.2f") { $0.shadows = $1 }
            slider("对比度", value: edit.contrast, range: -1...1, format: "%+.2f") { $0.contrast = $1 }
            slider("自然饱和度", value: edit.vibrance, range: -1...1, format: "%+.2f") { $0.vibrance = $1 }

            HStack {
                Button("同步到本组") { model.syncEditToGroup() }
                    .help("当前全部参数套用到本组未淘汰的照片")
                Button("风格和人像套用到全部已选") { model.applyStyleToAllPicked() }
                    .help("只同步风格、力度和人像修复，各张的曝光等微调保留")
            }
            .disabled(photo.edit == nil)
        }
    }

    private func slider(
        _ title: String, value: Double, range: ClosedRange<Double>, format: String, scale: Double = 1,
        update: @escaping (inout EditSettings, Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value * scale))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { value },
                set: { newValue in
                    var edit = photo.edit ?? .neutral
                    update(&edit, newValue)
                    model.updateEdit(edit)
                }
            ), in: range) { editing in
                // 整次拖动只记一步撤销
                if editing { model.beginEditChange(title) }
            }
            .controlSize(.small)
        }
    }
}
