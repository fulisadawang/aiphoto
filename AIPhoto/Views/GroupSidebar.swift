import SwiftUI

struct GroupSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("筛选", selection: $model.filter) {
                ForEach(AppModel.Filter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            List(selection: Binding(
                get: { model.selectedGroupID },
                set: { model.selectGroup($0) }
            )) {
                ForEach(model.visibleGroups) { group in
                    GroupRow(group: group)
                        .tag(Optional(group.id))
                }
            }
            .listStyle(.sidebar)
        }
    }
}

struct GroupRow: View {
    @Environment(AppModel.self) private var model
    let group: PhotoGroup

    var body: some View {
        let members = model.members(of: group)
        let picked = members.filter { $0.decision == .pick }.count
        let reviewed = members.contains { $0.ai != nil }
        let confirmed = members.contains(where: \.decidedByUser)

        HStack(spacing: 10) {
            if let cover = model.representative(of: group) {
                Thumbnail(url: cover.displayURL, size: CGSize(width: 64, height: 48))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("第 \(group.id) 组")
                        .fontWeight(.medium)
                    if model.aiRun?.running.contains(group.id) == true {
                        ProgressView()
                            .controlSize(.mini)
                            .help("AI 正在评估这一组")
                    } else if model.aiRun?.queued.contains(group.id) == true {
                        Image(systemName: "clock")
                            .foregroundStyle(.secondary)
                            .help("排队等 AI 评估")
                    } else if reviewed {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.purple)
                            .help("已经过 AI 评估")
                    }
                    if confirmed {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.blue)
                            .help("你已确认过")
                    }
                }
                Text(picked > 0 ? "\(members.count) 张 · 选 \(picked)" : "\(members.count) 张")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 方形裁切的缩略图
struct Thumbnail: View {
    let url: URL
    let size: CGSize
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            image = ImageCache.shared.cached(url, maxPixel: 320)
            if image == nil {
                image = await ImageCache.shared.load(url, maxPixel: 320)
            }
        }
    }
}
