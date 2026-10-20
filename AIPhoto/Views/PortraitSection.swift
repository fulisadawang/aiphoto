import SwiftUI

/// 人像修复：默认作用于所有人脸；合影可在大图上点选某张脸单独调整
struct PortraitSection: View {
    @Environment(AppModel.self) private var model
    let photo: Photo

    private var faces: [FaceInfo] { photo.analysis?.faces ?? [] }

    var body: some View {
        let amounts = model.currentPortrait
        Section {
            if faces.isEmpty {
                Text("这张照片没有检测到人脸，人像修复不会生效。")
                    .foregroundStyle(.secondary)
            } else {
                target
                if model.shapingPhotoIDs.contains(photo.id) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在定位五官…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if faces.contains(where: { $0.shape == nil }) {
                    Text("有的脸没能定位五官（侧脸、遮挡或太小），这些脸只做皮肤柔化。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            HStack {
                Text("人像")
                Spacer()
                Toggle("对比 \\", isOn: Binding(get: { model.compareMode }, set: { model.compareMode = $0 }))
                    .toggleStyle(.button)
                    .controlSize(.small)
            }
        }
        if !faces.isEmpty {
            Section("皮肤") {
                slider("磨皮", amounts.skin) { $0.skin = $1 }
                slider("黑眼圈", amounts.darkCircles) { $0.darkCircles = $1 }
            }
            Section("五官") {
                slider("亮眼", amounts.eyeBrighten) { $0.eyeBrighten = $1 }
                slider("牙齿美白", amounts.teeth) { $0.teeth = $1 }
            }
            Section {
                slider("瘦脸", amounts.faceSlim) { $0.faceSlim = $1 }
                slider("大眼", amounts.eyeEnlarge) { $0.eyeEnlarge = $1 }
            } header: {
                Text("脸型")
            } footer: {
                Text("孩子的脸建议轻一点；按 \\ 对比前后。滑块数值可以存进预设。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var target: some View {
        if faces.count > 1 {
            HStack {
                if let face = model.portraitFace {
                    Label("只调整人脸 \(face + 1)", systemImage: "person.crop.square")
                    Spacer()
                    if photo.edit?.faceOverrides?[face] != nil {
                        Button("跟随全部") { model.resetPortraitFace() }
                            .help("这张脸不再单独调整，跟随全部人脸的数值")
                    }
                    Button("全部人脸") { model.portraitFace = nil }
                } else {
                    Label("调整全部 \(faces.count) 张脸", systemImage: "person.2.crop.square.stack")
                    Spacer()
                }
            }
            .controlSize(.small)
            if model.portraitFace == nil {
                Text("在大图上点某张脸可以单独调整它。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Label("调整这张脸", systemImage: "person.crop.square")
        }
    }

    private func slider(_ title: String, _ value: Double, update: @escaping (inout PortraitAmounts, Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.0f", value * 100))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { value },
                set: { newValue in
                    var amounts = model.currentPortrait
                    update(&amounts, newValue)
                    model.updatePortrait(amounts)
                }
            ), in: 0...1) { editing in
                // 整次拖动只记一步撤销
                if editing { model.beginEditChange(title) }
            }
            .controlSize(.small)
        }
    }
}
