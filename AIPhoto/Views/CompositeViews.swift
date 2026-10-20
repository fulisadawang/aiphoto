import SwiftUI

/// 右侧面板里的入口
struct CompositeEntrySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section("合成") {
            Button {
                model.showCompositePicker = true
            } label: {
                Label("从同一场的其他照片取…", systemImage: "square.on.square.dashed")
            }
            .disabled(model.isBusy)
            .help("把另一张照片里的人或东西拿到这张来；全家福有人闭眼时，可以从相邻连拍里换一张睁眼的")
        }
    }
}

/// 选来源照片：同一组连拍排在最前
struct CompositeSourcePicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从哪张照片里取？").font(.title3.bold())
            Text("同一组连拍排在最前面：连拍会自动对齐，适合换人、换脸；其他照片需要手动摆放。")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(model.compositeSourceCandidates) { photo in
                        Button {
                            dismiss()
                            model.beginComposite(sourceID: photo.id)
                        } label: {
                            VStack(spacing: 4) {
                                Thumbnail(url: photo.displayURL, size: CGSize(width: 150, height: 108))
                                Text(photo.fileName).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
    }
}

/// 合成进行中，右侧面板换成操作说明和按钮
struct CompositePanel: View {
    @Environment(AppModel.self) private var model
    let session: CompositeSession

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 14) {
            Label("合成", systemImage: "square.on.square.dashed").font(.headline)
            if let source = model.photos[session.sourceID], let target = model.photos[session.targetID] {
                Text("从 \(source.fileName) 取，放到 \(target.fileName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let status = session.status {
                Text(status).font(.callout)
            }

            switch session.stage {
            case .selecting:
                Text("第 1 步：在大图上点一下要拿过来的人或东西，选中的部分会染成蓝色。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Toggle("补选", isOn: Binding(get: { session.refineAdd == true }, set: { _ in model.toggleCompositeRefine(add: true) }))
                    Toggle("擦除", isOn: Binding(get: { session.refineAdd == false }, set: { _ in model.toggleCompositeRefine(add: false) }))
                    if session.refineAdd != nil {
                        Slider(value: $model.brushSize, in: 0.005...0.08).frame(width: 90)
                    }
                }
                .toggleStyle(.button)
                .disabled(session.segmentation == nil)
                Button("放到当前照片") { model.confirmCompositeSelection() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.mask == nil)

            case .placing:
                Text("第 2 步：在大图上拖动调整位置，拖右下角的圆点调大小。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("水平翻转") { model.flipCompositePlacement() }
                    if session.alignedPlacement != nil {
                        Button("重新对齐") { model.realignComposite() }
                            .help("恢复连拍自动对齐的位置")
                    }
                }
                Toggle("完成后让 AI 融合边缘和影子", isOn: Binding(
                    get: { session.blendWithAI },
                    set: { model.composite?.blendWithAI = $0 }
                ))
                Text("AI 会重画这一块来对齐光线、补上影子，约 30～60 秒，人物长相可能有细微变化。连拍换人一般不需要。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("完成合成") { model.finishComposite() }
                    .buttonStyle(.borderedProminent)
            }

            Divider()
            Button("取消合成  Esc") { model.cancelComposite() }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 选取阶段：叠在来源照片上，点击选中主体，选中部分染色
struct CompositeSelectOverlay: View {
    @Environment(AppModel.self) private var model
    let session: CompositeSession

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let overlay = session.maskOverlay {
                    Image(decorative: overlay, scale: 1).resizable().allowsHitTesting(false)
                }
                if session.refineAdd != nil {
                    BrushOverlay()
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { location in
                            model.compositeTap(at: CGPoint(
                                x: location.x / geometry.size.width, y: location.y / geometry.size.height
                            ))
                        }
                }
            }
        }
    }
}

/// 放置阶段：叠在当前照片上，拖动移动，右下角圆点缩放
struct CompositePlaceOverlay: View {
    @Environment(AppModel.self) private var model
    let session: CompositeSession
    @State private var dragStart: CGRect?

    var body: some View {
        GeometryReader { geometry in
            if let placement = session.placement, let preview = session.subjectPreview {
                let size = geometry.size
                let frame = CGRect(
                    x: placement.rect.minX * size.width, y: placement.rect.minY * size.height,
                    width: placement.rect.width * size.width, height: placement.rect.height * size.height
                )
                ZStack(alignment: .bottomTrailing) {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .scaleEffect(x: placement.flipped ? -1 : 1, y: 1)
                        .overlay(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 14, height: 14)
                        .offset(x: 7, y: 7)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let start = dragStart ?? placement.rect
                                    dragStart = start
                                    // 保持主体宽高比，按横向拖动距离缩放
                                    let width = max(0.02, start.width + value.translation.width / size.width)
                                    let height = width * start.height / start.width
                                    model.moveCompositePlacement(to: CGRect(x: start.minX, y: start.minY, width: width, height: height))
                                }
                                .onEnded { _ in dragStart = nil }
                        )
                }
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
                .position(x: frame.midX, y: frame.midY)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let start = dragStart ?? placement.rect
                            dragStart = start
                            model.moveCompositePlacement(to: start.offsetBy(
                                dx: value.translation.width / size.width, dy: value.translation.height / size.height
                            ))
                        }
                        .onEnded { _ in dragStart = nil }
                )
            }
        }
    }
}
