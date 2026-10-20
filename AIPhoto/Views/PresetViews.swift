import SwiftUI

/// 修图面板里的预设入口：套用到当前或全部已选、存为预设、管理
struct PresetMenu: View {
    @Environment(AppModel.self) private var model
    let photo: Photo

    var body: some View {
        HStack {
            Menu("套用预设") {
                if model.presets.isEmpty {
                    Text("还没有预设")
                }
                Section("套用到当前照片") {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.applyPreset(preset, to: [photo.id]) }
                    }
                }
                Section("套用到全部已选（\(model.pickedPhotoIDs.count) 张）") {
                    ForEach(model.presets) { preset in
                        Button(preset.name) { model.applyPreset(preset, to: model.pickedPhotoIDs) }
                    }
                }
            }
            .help("按预设重新调色：每张先自动校正明暗，再叠加预设；去杂物结果保留")
            Button("存为预设…") { model.showSavePreset = true }
                .help("把这张照片的风格、磨皮、对比度等存成预设（不存曝光和色温）")
            Button("管理…") { model.showPresetManager = true }
        }
        .disabled(model.isBusy)
    }
}

/// 把当前照片的修图存为预设
struct SavePresetSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("存为预设").font(.title3.bold())
            Text("记下这张照片的风格、磨皮、对比度、饱和度、高光阴影和色调（相对自动调色多调的部分）。曝光和色温不存，套用时按每张照片的光线自动决定。")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("预设名称，如「秋日暖调」", text: $name)
            Text("给 AI 的描述（可选）").font(.callout)
            NoteEditor(text: $note)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    model.saveCurrentAsPreset(name: name.trimmingCharacters(in: .whitespaces), note: note)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// 预设管理：左边列表，右边编辑
struct PresetManagerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    List(selection: $selection) {
                        ForEach(model.presets) { preset in
                            HStack {
                                Text(preset.name)
                                Spacer()
                                if preset.id == model.defaultPresetID {
                                    Text("默认").badgeStyle(.blue)
                                }
                            }
                            .tag(preset.id)
                        }
                    }
                    HStack {
                        Button { selection = model.addPreset().id } label: { Image(systemName: "plus") }
                        Button {
                            if let selection { model.deletePreset(selection) }
                            selection = nil
                        } label: { Image(systemName: "minus") }
                        .disabled(selection == nil)
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .padding(8)
                }
                .frame(width: 190)
                Divider()
                if let selection, let preset = model.presets.first(where: { $0.id == selection }) {
                    PresetEditor(preset: preset)
                        .id(preset.id)
                } else {
                    ContentUnavailableView(
                        model.presets.isEmpty ? "还没有预设" : "选择一个预设",
                        systemImage: "slider.horizontal.3",
                        description: Text("点左下角 + 新建，或在修图面板里把修好的照片「存为预设」。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 560)
        .onAppear { selection = model.defaultPresetID ?? model.presets.first?.id }
    }
}

private struct PresetEditor: View {
    @Environment(AppModel.self) private var model
    let preset: RetouchPreset

    var body: some View {
        Form {
            TextField("名称", text: binding(\.name))
            Toggle("设为默认（一键初修时自动选中）", isOn: Binding(
                get: { model.defaultPresetID == preset.id },
                set: { model.setDefaultPreset($0 ? preset.id : nil) }
            ))
            Section("给 AI 的描述") {
                NoteEditor(text: binding(\.note))
                Text("一键初修和套用预设时，AI 按描述换算出整场统一的冷暖、通透、饱和度调整；去杂物和对话改图也会参考，比如「地上的落叶保留」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("风格与皮肤") {
                Picker("风格", selection: binding(\.styleID)) {
                    Text("无").tag(UUID?.none)
                    ForEach(model.styles) { Text($0.name).tag(Optional($0.id)) }
                }
                if preset.styleID != nil {
                    slider("风格力度", \.styleStrength, 0...1, "%.0f%%", scale: 100)
                }
                slider("皮肤柔化", \.skinSmoothing, 0...1, "%.0f%%", scale: 100)
            }
            Section("在自动调色基础上再调整") {
                slider("高光", \.highlights, -1...1, "%+.2f")
                slider("阴影", \.shadows, -1...1, "%+.2f")
                slider("色调", \.tint, -30...30, "%+.0f")
                slider("对比度", \.contrast, -1...1, "%+.2f")
                slider("自然饱和度", \.vibrance, -1...1, "%+.2f")
                Text("曝光和色温不在预设里：明暗由自动调色按每张光线决定，冷暖写在描述里或用风格。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<RetouchPreset, Value>) -> Binding<Value> {
        Binding(
            get: { model.presets.first { $0.id == preset.id }?[keyPath: keyPath] ?? preset[keyPath: keyPath] },
            set: { value in
                var updated = model.presets.first { $0.id == preset.id } ?? preset
                updated[keyPath: keyPath] = value
                model.updatePreset(updated)
            }
        )
    }

    private func slider(
        _ title: String, _ keyPath: WritableKeyPath<RetouchPreset, Double>, _ range: ClosedRange<Double>,
        _ format: String, scale: Double = 1
    ) -> some View {
        let value = binding(keyPath)
        return LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(String(format: format, value.wrappedValue * scale))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }
}

/// 多行描述输入框
struct NoteEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.callout)
            .frame(minHeight: 70, maxHeight: 110)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("如：整体通透偏暖，肤色红润不要偏黄；背景杂物都去掉，地上的落叶保留")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
    }
}
