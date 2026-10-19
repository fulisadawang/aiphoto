import SwiftUI

struct PhotoViewer: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    @State private var image: CGImage?
    @State private var renderError: String?

    private static let previewPixels = 3000

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.08)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay {
                            if model.showFaces, let faces = photo.analysis?.faces {
                                FaceOverlay(faces: faces)
                            }
                        }
                        .overlay {
                            if model.brushMode { BrushOverlay() }
                        }
                        // 放大时以最大人脸为中心，方便检查眼睛和对焦
                        .scaleEffect(model.zoomed ? 3 : 1, anchor: zoomAnchor)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .onTapGesture(count: 2) { if !model.brushMode { model.zoomed.toggle() } }
                } else {
                    ProgressView()
                }
            }
        }
        .overlay(alignment: .topLeading) { badges.padding(12) }
        .task(id: RenderKey(
            url: photo.displayURL,
            edit: model.showOriginal ? nil : photo.edit,
            patches: model.showOriginal ? [] : photo.cleanups ?? []
        )) {
            let url = photo.displayURL
            let edit = model.showOriginal ? nil : photo.edit
            let patches = model.showOriginal ? [] : photo.cleanups ?? []
            let faces = photo.analysis?.faces ?? []
            renderError = nil
            if edit == nil && patches.isEmpty {
                image = ImageCache.shared.cached(url, maxPixel: Self.previewPixels)
                    ?? ImageCache.shared.cached(url, maxPixel: 320)
            }
            guard edit != nil || !patches.isEmpty, let folder = model.folderURL else {
                if let base = await ImageCache.shared.load(url, maxPixel: Self.previewPixels) { image = base }
                return
            }
            // 修过的照片用 RAW 解码做底图，和导出成片一致；解码期间先显示已缓存的 JPG
            if image == nil { image = ImageCache.shared.cached(url, maxPixel: Self.previewPixels) }
            guard let base = await ImageCache.shared.load(photo.editURL, maxPixel: Self.previewPixels, editBase: true) else { return }
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
    }

    private struct RenderKey: Equatable {
        let url: URL
        let edit: EditSettings?
        let patches: [CleanupPatch]
    }

    private var zoomAnchor: UnitPoint {
        guard let focus = photo.analysis?.focusRect else { return .center }
        return UnitPoint(x: focus.midX, y: focus.midY)
    }

    private var badges: some View {
        HStack(spacing: 6) {
            DecisionBadge(decision: photo.decision)
            if photo.edit != nil || photo.cleanups != nil {
                Text(model.showOriginal ? "原图" : "已修图").badgeStyle(model.showOriginal ? .gray : .blue)
            }
            if model.brushMode {
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

    var body: some View {
        GeometryReader { geometry in
            ForEach(faces, id: \.self) { face in
                let rect = CGRect(
                    x: face.box.minX * geometry.size.width, y: face.box.minY * geometry.size.height,
                    width: face.box.width * geometry.size.width, height: face.box.height * geometry.size.height
                )
                Rectangle()
                    .stroke(face.isBlinking ? Color.orange : Color.green, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
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
                    .onEnded { _ in drawing = false }
            )
        }
    }
}
