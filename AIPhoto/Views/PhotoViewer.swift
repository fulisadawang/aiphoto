import SwiftUI

struct PhotoViewer: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    /// 修复后的图（没修过时就是原图）
    @State private var image: CGImage?
    /// 对比模式左侧的原图：与修复后用同一底图（有 RAW 时为 RAW 解码），只是不加任何修复
    @State private var originalImage: CGImage?
    @State private var pixelSize: CGSize?
    @State private var renderError: String?
    @State private var peakingMask: CGImage?
    @State private var clippingMask: CGImage?
    @State private var afAreas: [CGRect] = []

    private static let previewPixels = 3000

    private var isEdited: Bool { photo.edit != nil || photo.cleanups != nil }

    var body: some View {
        ZStack {
            Color(white: 0.08)
            if let image, let pixelSize {
                ZoomableImage(
                    image: image,
                    compareImage: model.compareMode ? (originalImage ?? image) : nil,
                    pixelSize: pixelSize,
                    allowsDragPan: !model.brushMode && !model.isCompositing
                ) {
                    ZStack {
                        if model.showPeaking, let peakingMask {
                            Image(decorative: peakingMask, scale: 1).resizable().allowsHitTesting(false)
                        }
                        if model.showClipping, let clippingMask {
                            Image(decorative: clippingMask, scale: 1).resizable().allowsHitTesting(false)
                        }
                        if model.showFaces {
                            FaceOverlay(faces: photo.analysis?.faces ?? [], afAreas: afAreas)
                        }
                        if let session = model.composite {
                            if session.stage == .selecting, photo.id == session.sourceID {
                                CompositeSelectOverlay(session: session)
                            } else if session.stage == .placing, photo.id == session.targetID {
                                CompositePlaceOverlay(session: session)
                            }
                        } else if model.brushMode {
                            BrushOverlay()
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .topLeading) { badges.padding(12) }
        .overlay(alignment: .bottomTrailing) { viewControls.padding(12) }
        .task(id: photo.displayURL) {
            let url = photo.displayURL, jpg = photo.renderedURL, raw = photo.rawURL
            pixelSize = await Task.detached { ImageLoader.orientedPixelSize(at: url) }.value
            // 有 JPG 时从 JPG 读（解析快），否则读 RAW
            afAreas = await Task.detached { AFPointReader.focusedAreas(at: jpg ?? raw ?? url) }.value
        }
        .task(id: RenderKey(
            url: photo.displayURL,
            edit: photo.edit,
            patches: photo.cleanups ?? [],
            maxPixel: neededPixels,
            compare: model.compareMode
        )) {
            await renderImages()
        }
        .task(id: AidKey(image: image.map(ObjectIdentifier.init), peaking: model.showPeaking, clipping: model.showClipping)) {
            guard let image else { return }
            let peaking = model.showPeaking, clipping = model.showClipping
            let result = await Task.detached(priority: .utility) {
                (ViewingAids.histogram(of: image),
                 peaking ? ViewingAids.peakingMask(of: image) : nil,
                 clipping ? ViewingAids.clippingMask(of: image) : nil)
            }.value
            guard !Task.isCancelled else { return }
            model.histogram = result.0
            peakingMask = result.1
            clippingMask = result.2
        }
    }

    private func renderImages() async {
        let url = photo.displayURL
        let maxPixel = neededPixels
        let edit = photo.edit
        let patches = photo.cleanups ?? []
        let faces = photo.analysis?.faces ?? []
        renderError = nil
        guard isEdited, let folder = model.folderURL else {
            // 没修过：先显示已有的较低分辨率，再加载需要的分辨率；原图与修复后相同
            image = ImageCache.shared.cached(url, maxPixel: maxPixel)
                ?? ImageCache.shared.cached(url, maxPixel: Self.previewPixels)
                ?? (image ?? ImageCache.shared.cached(url, maxPixel: 320))
            if let base = await ImageCache.shared.load(url, maxPixel: maxPixel) { image = base }
            originalImage = nil
            return
        }
        // 修过的照片用 RAW 解码做底图，和导出成片一致；解码期间先显示已缓存的 JPG
        if image == nil { image = ImageCache.shared.cached(url, maxPixel: Self.previewPixels) }
        guard let base = await ImageCache.shared.load(photo.editURL, maxPixel: maxPixel, editBase: true) else { return }
        if model.compareMode { originalImage = base }
        // 拖动滑块时任务会被频繁取消重建，渲染完再检查一次，避免旧结果覆盖新结果
        let result = await Task.detached(priority: .userInitiated) {
            Result { try PhotoRenderer.render(base, edit: edit, faces: faces, patches: patches, folder: folder) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let rendered): image = rendered ?? base
        case .failure(let error):
            image = base
            renderError = error.localizedDescription
        }
    }

    /// 放大到超过预览分辨率时改用全尺寸，100%、200% 下看到的是真实像素
    private var neededPixels: Int {
        guard let ratio = model.zoom.pixelRatio, let pixelSize else { return Self.previewPixels }
        let longEdge = max(pixelSize.width, pixelSize.height)
        return ratio * longEdge > CGFloat(Self.previewPixels) * 1.1 ? Int(longEdge) : Self.previewPixels
    }

    private struct RenderKey: Equatable {
        let url: URL
        let edit: EditSettings?
        let patches: [CleanupPatch]
        let maxPixel: Int
        let compare: Bool
    }

    private struct AidKey: Equatable {
        let image: ObjectIdentifier?
        let peaking: Bool
        let clipping: Bool
    }

    /// 右下角：看片辅助开关和缩放倍数
    private var viewControls: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
            Toggle("合焦 K", isOn: $model.showPeaking)
            Toggle("过曝 J", isOn: $model.showClipping)
            Toggle("人脸/对焦点 F", isOn: $model.showFaces)
            Text(model.zoom.pixelRatio.map { "\(Int(($0 * 100).rounded()))%" } ?? "适应窗口")
                .badgeStyle(.black)
                .help("Z：适应窗口 / 100% / 200%　空格：放大到人脸　滚轮或双指：缩放与平移　双击：放大到点击处")
        }
        .toggleStyle(.button)
        .controlSize(.small)
    }

    private var badges: some View {
        HStack(spacing: 6) {
            DecisionBadge(decision: photo.decision)
            if isEdited, !model.compareMode {
                Text("已修图").badgeStyle(.blue)
            }
            if model.compareMode, !isEdited {
                Text("这张还没有修复，左右相同").badgeStyle(.gray)
            }
            if let session = model.composite {
                Text(session.stage == .selecting ? "合成：这是来源照片，点选要拿的东西" : "合成：调整位置后点「完成合成」").badgeStyle(.indigo)
            } else if model.brushMode {
                Text("画笔：涂抹要去掉的物体，回车消除，Esc 清除").badgeStyle(.pink)
            }
            if let renderError {
                Text(renderError).badgeStyle(.red)
            }
            if let ai = photo.ai {
                Label("AI \(ai.score)", systemImage: ai.pick ? "star.fill" : "sparkles")
                    .badgeStyle(ai.pick ? .purple : .gray)
            }
            ForEach(photo.flags.sorted { $0.rawValue < $1.rawValue }, id: \.self) { flag in
                Text(flag.label).badgeStyle(.orange)
            }
            if photo.rating > 0 {
                Text(String(repeating: "★", count: photo.rating)).badgeStyle(.yellow)
            }
        }
    }
}

struct FaceOverlay: View {
    let faces: [FaceInfo]
    /// 相机记录的合焦对焦框
    var afAreas: [CGRect] = []

    var body: some View {
        GeometryReader { geometry in
            ForEach(faces, id: \.self) { face in
                Rectangle()
                    .stroke(face.isBlinking ? Color.orange : Color.green, lineWidth: 2)
                    .frame(width: face.box.width * geometry.size.width, height: face.box.height * geometry.size.height)
                    .position(x: face.box.midX * geometry.size.width, y: face.box.midY * geometry.size.height)
            }
            ForEach(Array(afAreas.enumerated()), id: \.offset) { _, area in
                Rectangle()
                    .stroke(Color.yellow, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .frame(width: max(12, area.width * geometry.size.width), height: max(12, area.height * geometry.size.height))
                    .position(x: area.midX * geometry.size.width, y: area.midY * geometry.size.height)
                    .help("相机对焦点")
            }
        }
        .allowsHitTesting(false)
    }

}

struct DecisionBadge: View {
    let decision: Decision

    var body: some View {
        switch decision {
        case .pick: Label("已选", systemImage: "checkmark.circle.fill").badgeStyle(.green)
        case .reject: Label("淘汰", systemImage: "xmark.circle.fill").badgeStyle(.red)
        case .none: EmptyView()
        }
    }
}

extension View {
    func badgeStyle(_ color: Color) -> some View {
        font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.85), in: Capsule())
    }
}

/// 画笔涂抹层：坐标按图片显示区域归一化，与原图分辨率无关
struct BrushOverlay: View {
    @Environment(AppModel.self) private var model
    @State private var drawing = false

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                for stroke in model.strokes {
                    let width = stroke.radius * size.width * 2
                    var path = Path()
                    let points = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                    if points.count == 1 {
                        path.addEllipse(in: CGRect(x: points[0].x - width / 2, y: points[0].y - width / 2, width: width, height: width))
                        context.fill(path, with: .color(.pink.opacity(0.5)))
                    } else {
                        path.addLines(points)
                        context.stroke(path, with: .color(.pink.opacity(0.5)), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let point = CGPoint(
                            x: min(1, max(0, value.location.x / geometry.size.width)),
                            y: min(1, max(0, value.location.y / geometry.size.height))
                        )
                        if drawing {
                            model.extendStroke(to: point)
                        } else {
                            drawing = true
                            model.beginStroke(at: point)
                        }
                    }
                    .onEnded { _ in
                        drawing = false
                        // 合成时的画笔修正一笔就生效
                        if model.composite?.refineAdd != nil { model.applyCompositeStroke() }
                    }
            )
        }
    }
}
