import SwiftUI

/// 网格总览：按连拍组排列整场照片，可单选、⌘ / ⇧ 多选、框选后批量选用或淘汰
struct GridView: View {
    @Environment(AppModel.self) private var model
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var marquee: CGRect?

    private static let space = "grid"

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header(thumbSize: $model.gridThumbSize)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.visibleGroups) { group in
                            section(group)
                        }
                    }
                    .padding(14)
                    .background(marqueeGestureLayer)
                    .overlay(alignment: .topLeading) {
                        if let marquee {
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.15))
                                .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1))
                                .frame(width: marquee.width, height: marquee.height)
                                .offset(x: marquee.minX, y: marquee.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .coordinateSpace(name: Self.space)
                }
                .onChange(of: model.selectedPhotoID) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) } }
                }
                .onAppear { if let id = model.selectedPhotoID { proxy.scrollTo(id, anchor: .center) } }
            }
            .onPreferenceChange(CellFrameKey.self) { cellFrames = $0 }
        }
    }

    private func header(thumbSize: Binding<CGFloat>) -> some View {
        let all = model.photos.values
        let picked = all.filter { $0.decision == .pick }.count
        let rejected = all.filter { $0.decision == .reject }.count
        let retouched = all.filter { $0.retouchLog != nil && !model.isCleaning($0.id) }.count
        return HStack(spacing: 14) {
            Text("共 \(all.count) 张 · 已选 \(picked) · 淘汰 \(rejected) · 待定 \(all.count - picked - rejected) · 初修完成 \(retouched)")
                .monospacedDigit()
            if model.gridSelection.count > 1 {
                Text("已框选 \(model.gridSelection.count) 张：P 选用　X 淘汰　U 取消")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "photo").imageScale(.small)
            Slider(value: thumbSize, in: 90...320).frame(width: 140)
            Image(systemName: "photo").imageScale(.large)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func section(_ group: PhotoGroup) -> some View {
        let members = model.members(of: group)
        let picked = members.filter { $0.decision == .pick }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("第 \(group.id) 组").fontWeight(.semibold)
                Text("\(members.count) 张").foregroundStyle(.secondary)
                Text(picked > 0 ? "已选 \(picked)" : "还没选").foregroundStyle(picked > 0 ? .green : .orange)
            }
            .font(.callout)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: model.gridThumbSize), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(members) { photo in
                    GridCell(photo: photo, size: model.gridThumbSize, isSelected: model.gridSelection.contains(photo.id), isCurrent: photo.id == model.selectedPhotoID)
                        .id(photo.id)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: CellFrameKey.self, value: [photo.id: proxy.frame(in: .named(Self.space))])
                        })
                        .onTapGesture(count: 2) { model.openInViewer(photo.id) }
                        .onTapGesture {
                            // 同一个单击里读修饰键，避免普通单击把 ⌘ / ⇧ 多选又重置成单选
                            let flags = NSEvent.modifierFlags
                            model.gridClick(photo.id, command: flags.contains(.command), shift: flags.contains(.shift))
                        }
                }
            }
        }
    }

    /// 在空白处拖动出框，框到的照片全部选中；按住 ⌘ 追加
    private var marqueeGestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        let rect = CGRect(
                            x: min(value.startLocation.x, value.location.x), y: min(value.startLocation.y, value.location.y),
                            width: abs(value.location.x - value.startLocation.x), height: abs(value.location.y - value.startLocation.y)
                        )
                        marquee = rect
                        let hits = Set(cellFrames.filter { $0.value.intersects(rect) }.keys)
                        model.gridMarquee(hits, adding: NSEvent.modifierFlags.contains(.command))
                    }
                    .onEnded { _ in marquee = nil }
            )
    }
}

private struct CellFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct GridCell: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    let size: CGFloat
    let isSelected: Bool
    let isCurrent: Bool

    var body: some View {
        Thumbnail(url: photo.displayURL, size: CGSize(width: size, height: size * 0.72))
            .opacity(photo.decision == .reject ? 0.35 : 1)
            .overlay(alignment: .topLeading) {
                Group {
                    switch photo.decision {
                    case .pick: Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
                    case .reject: Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .red)
                    case .none: EmptyView()
                    }
                }
                .font(.title3)
                .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if let ai = photo.ai {
                    Label("\(ai.score)", systemImage: ai.pick ? "star.fill" : "sparkles")
                        .badgeStyle(ai.pick ? .purple : .gray)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if model.isCleaning(photo.id) {
                        Text("修复中").badgeStyle(.blue)
                    } else if photo.retouchLog?.needsReview == true {
                        Text("需检查").badgeStyle(.pink)
                    } else if photo.retouchLog != nil {
                        Text("已初修").badgeStyle(.teal)
                    }
                    ForEach(photo.flags.sorted { $0.rawValue < $1.rawValue }, id: \.self) { flag in
                        Text(flag.label).badgeStyle(.orange)
                    }
                }
                .padding(4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isSelected ? Color.accentColor : isCurrent ? Color.accentColor.opacity(0.5) : .clear, lineWidth: isSelected ? 3 : 2)
            }
            .help(photo.fileName)
    }
}
