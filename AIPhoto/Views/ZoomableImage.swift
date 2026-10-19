import AppKit
import SwiftUI

/// 放大状态。pixelRatio 为"屏幕像素 / 原图像素"：nil 表示适应窗口，1 表示 100%（与 Lightroom 1:1 一致）
struct ZoomState: Equatable {
    var pixelRatio: CGFloat?
    /// 视口中心对应的原图位置，归一化坐标（原点左上）
    var center = CGPoint(x: 0.5, y: 0.5)

    static let maxRatio: CGFloat = 4

    /// Z 键：适应窗口 → 100% → 200% → 适应窗口
    mutating func cycle() {
        switch pixelRatio {
        case nil: pixelRatio = 1
        case let ratio? where ratio < 2: pixelRatio = 2
        default: pixelRatio = nil
        }
    }
}

/// 可放大平移的图片。放大状态存在 AppModel 里，切换照片时保持不变。
/// overlay 放在图片自身的坐标系里，人脸框、画笔等跟随缩放和平移
struct ZoomableImage<Overlay: View>: View {
    @Environment(AppModel.self) private var model
    let image: CGImage
    /// 修复前后对比时的原图，叠在左侧，到分割线为止
    var compareImage: CGImage?
    /// 原图（方向转正后）的像素尺寸，决定 100% 的含义；显示用的 image 可能是缩小过的预览
    let pixelSize: CGSize
    /// 画笔模式下拖动用于涂抹，不平移
    let allowsDragPan: Bool
    @ViewBuilder let overlay: () -> Overlay

    @State private var wheel = WheelTracker()
    @State private var dragStartCenter: CGPoint?
    @State private var pinchStartRatio: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let layout = ZoomLayout(viewSize: geometry.size, pixelSize: pixelSize, zoom: model.zoom)
            ZStack {
                imageLayer(image, layout: layout, viewSize: geometry.size)
                if let compareImage {
                    // 分割线固定在视口上，放大平移时左右两半始终是同一位置的修复前后
                    imageLayer(compareImage, layout: layout, viewSize: geometry.size)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geometry.size.width * model.compareDivider)
                        }
                }
                // 叠加层（人脸框、对焦点、合焦高亮、画笔）放在图片坐标系里，跟随缩放平移
                Color.clear
                    .frame(width: layout.imageSize.width, height: layout.imageSize.height)
                    .overlay { overlay() }
                    .position(layout.imageCenter)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .clipped()
            .gesture(panGesture(layout), including: allowsDragPan ? .all : .subviews)
            .simultaneousGesture(pinchGesture(layout))
            .onTapGesture(count: 2) { location in
                guard allowsDragPan else { return }
                if model.zoom.pixelRatio == nil {
                    model.zoom = ZoomState(pixelRatio: 1, center: layout.normalizedPoint(at: location))
                } else {
                    model.zoom.pixelRatio = nil
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    wheel.location = location
                    wheel.layout = layout
                case .ended:
                    wheel.location = nil
                }
            }
            .overlay {
                if compareImage != nil { CompareDivider(viewSize: geometry.size) }
            }
            .overlay(alignment: .bottomLeading) {
                if model.zoom.pixelRatio != nil {
                    Navigator(image: image, layout: layout).padding(12)
                }
            }
            .onAppear { wheel.layout = layout }
            .onChange(of: layout) { _, new in wheel.layout = new }
        }
        .onAppear { wheel.install(model: model) }
        .onDisappear { wheel.uninstall() }
    }

    private func imageLayer(_ cgImage: CGImage, layout: ZoomLayout, viewSize: CGSize) -> some View {
        Image(decorative: cgImage, scale: 1)
            .resizable()
            .interpolation(layout.pointsPerPixel > 1.5 ? .none : .high)
            .frame(width: layout.imageSize.width, height: layout.imageSize.height)
            .position(layout.imageCenter)
            .frame(width: viewSize.width, height: viewSize.height)
    }

    private func panGesture(_ layout: ZoomLayout) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard model.zoom.pixelRatio != nil else { return }
                let start = dragStartCenter ?? model.zoom.center
                dragStartCenter = start
                model.zoom.center = layout.clamped(CGPoint(
                    x: start.x - value.translation.width / layout.imageSize.width,
                    y: start.y - value.translation.height / layout.imageSize.height
                ))
            }
            .onEnded { _ in dragStartCenter = nil }
    }

    private func pinchGesture(_ layout: ZoomLayout) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStartRatio ?? layout.currentRatio
                pinchStartRatio = start
                model.zoom.pixelRatio = layout.ratio(clamping: start * value.magnification)
            }
            .onEnded { _ in pinchStartRatio = nil }
    }
}

/// 修复前后对比的分割线：左原图、右修复后，拖动手柄改变位置。整层铺满大图，只有手柄接收拖动
struct CompareDivider: View {
    @Environment(AppModel.self) private var model
    let viewSize: CGSize

    var body: some View {
        let x = viewSize.width * model.compareDivider
        ZStack {
            Text("原图").badgeStyle(.gray).allowsHitTesting(false)
                .position(x: x / 2, y: 18)
            Text("修复后").badgeStyle(.blue).allowsHitTesting(false)
                .position(x: x + (viewSize.width - x) / 2, y: 18)
            ZStack {
                Rectangle()
                    .fill(.white)
                    .frame(width: 2, height: viewSize.height)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                Image(systemName: "arrow.left.and.right.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            // 手柄区域加宽方便抓取；优先于平移和画笔
            .frame(width: 28, height: viewSize.height)
            .contentShape(Rectangle())
            .position(x: x, y: viewSize.height / 2)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("compareDivider"))
                    .onChanged { value in
                        model.compareDivider = min(0.98, max(0.02, value.location.x / max(1, viewSize.width)))
                    }
            )
        }
        .frame(width: viewSize.width, height: viewSize.height)
        .coordinateSpace(name: "compareDivider")
    }
}

/// 放大时左下角的全图缩略：框出当前查看的区域，点击或拖动跳转
struct Navigator: View {
    @Environment(AppModel.self) private var model
    let image: CGImage
    let layout: ZoomLayout

    private static let maxSide: CGFloat = 180

    var body: some View {
        let scale = Self.maxSide / max(layout.pixelSize.width, layout.pixelSize.height)
        let size = CGSize(width: layout.pixelSize.width * scale, height: layout.pixelSize.height * scale)
        let visible = layout.visibleRect
        Image(decorative: image, scale: 1)
            .resizable()
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .stroke(.yellow, lineWidth: 1.5)
                    .frame(width: visible.width * size.width, height: visible.height * size.height)
                    .offset(x: visible.minX * size.width, y: visible.minY * size.height)
            }
            .border(.white.opacity(0.6))
            .shadow(radius: 4)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        model.zoom.center = layout.clamped(CGPoint(
                            x: value.location.x / size.width, y: value.location.y / size.height
                        ))
                    }
            )
            .help("点击或拖动跳到对应位置")
    }
}

/// 根据视口、原图尺寸和放大状态算出图片的显示尺寸与位置
struct ZoomLayout: Equatable {
    let viewSize: CGSize
    let pixelSize: CGSize
    let zoom: ZoomState
    let backingScale: CGFloat

    init(viewSize: CGSize, pixelSize: CGSize, zoom: ZoomState) {
        self.viewSize = viewSize
        self.pixelSize = pixelSize
        self.zoom = zoom
        backingScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    /// 适应窗口时的"屏幕像素 / 原图像素"
    var fitRatio: CGFloat {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return 1 }
        return min(viewSize.width / pixelSize.width, viewSize.height / pixelSize.height) * backingScale
    }

    var currentRatio: CGFloat { zoom.pixelRatio.map { max($0, fitRatio) } ?? fitRatio }

    /// 每个原图像素占多少屏幕点
    var pointsPerPixel: CGFloat { currentRatio / backingScale }

    var imageSize: CGSize {
        CGSize(width: pixelSize.width * pointsPerPixel, height: pixelSize.height * pointsPerPixel)
    }

    var imageCenter: CGPoint {
        let center = zoom.pixelRatio == nil ? CGPoint(x: 0.5, y: 0.5) : clamped(zoom.center)
        return CGPoint(
            x: viewSize.width / 2 + (0.5 - center.x) * imageSize.width,
            y: viewSize.height / 2 + (0.5 - center.y) * imageSize.height
        )
    }

    /// 视口内一点对应的原图归一化坐标
    func normalizedPoint(at location: CGPoint) -> CGPoint {
        let origin = CGPoint(x: imageCenter.x - imageSize.width / 2, y: imageCenter.y - imageSize.height / 2)
        return CGPoint(
            x: min(1, max(0, (location.x - origin.x) / imageSize.width)),
            y: min(1, max(0, (location.y - origin.y) / imageSize.height))
        )
    }

    /// 当前视口能看到的原图区域，归一化坐标
    var visibleRect: CGRect {
        let center = zoom.pixelRatio == nil ? CGPoint(x: 0.5, y: 0.5) : clamped(zoom.center)
        let w = min(1, viewSize.width / imageSize.width), h = min(1, viewSize.height / imageSize.height)
        return CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
    }

    /// 放大后不让图片边缘离开视口；某方向比视口小时居中
    func clamped(_ center: CGPoint) -> CGPoint {
        func axis(_ value: CGFloat, image: CGFloat, view: CGFloat) -> CGFloat {
            guard image > view else { return 0.5 }
            let half = view / 2 / image
            return min(1 - half, max(half, value))
        }
        return CGPoint(
            x: axis(center.x, image: imageSize.width, view: viewSize.width),
            y: axis(center.y, image: imageSize.height, view: viewSize.height)
        )
    }

    /// 不小于适应窗口，不大于上限；接近适应窗口时回到"适应窗口"状态
    func ratio(clamping ratio: CGFloat) -> CGFloat? {
        ratio <= fitRatio * 1.02 ? nil : min(ZoomState.maxRatio, ratio)
    }
}

/// 鼠标滚轮放大、触控板双指平移。SwiftUI 在 macOS 上没有滚轮手势，用本地事件监听实现，
/// 只处理鼠标悬停在图片区域内的事件，其余照常放行
@MainActor
final class WheelTracker {
    var location: CGPoint?
    var layout: ZoomLayout?
    private var monitor: Any?

    func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let location = self.location, let layout = self.layout else { return event }
            if event.hasPreciseScrollingDeltas {
                // 触控板：放大时平移，未放大时不处理
                guard model.zoom.pixelRatio != nil else { return event }
                model.zoom.center = layout.clamped(CGPoint(
                    x: layout.clamped(model.zoom.center).x - event.scrollingDeltaX / layout.imageSize.width,
                    y: layout.clamped(model.zoom.center).y - event.scrollingDeltaY / layout.imageSize.height
                ))
            } else {
                // 鼠标滚轮：以指针为中心缩放，指针下的那一点保持不动
                guard event.scrollingDeltaY != 0 else { return event }
                let factor: CGFloat = event.scrollingDeltaY > 0 ? 1.15 : 1 / 1.15
                let anchor = layout.normalizedPoint(at: location)
                let oldRatio = layout.currentRatio
                guard let newRatio = layout.ratio(clamping: oldRatio * factor) else {
                    model.zoom.pixelRatio = nil
                    return nil
                }
                let oldCenter = model.zoom.pixelRatio == nil ? CGPoint(x: 0.5, y: 0.5) : layout.clamped(model.zoom.center)
                let keep = oldRatio / newRatio
                model.zoom = ZoomState(pixelRatio: newRatio, center: CGPoint(
                    x: anchor.x + (oldCenter.x - anchor.x) * keep,
                    y: anchor.y + (oldCenter.y - anchor.y) * keep
                ))
            }
            return nil
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
