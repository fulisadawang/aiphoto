import SwiftUI

struct GroupSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.shootMode == .editOnly {
            photoList
        } else {
            groupList
        }
    }

    /// 只修图：不分组，所有照片一个列表
    private var photoList: some View {
        let photos = model.groups.flatMap { model.members(of: $0) }
        return VStack(alignment: .leading, spacing: 0) {
            Text("全部照片 \(photos.count) 张")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            List(selection: Binding(
                get: { model.selectedPhotoID },
                set: { if let id = $0 { model.selectPhoto(id) } }
            )) {
                ForEach(photos) { photo in
                    HStack(spacing: 10) {
                        Thumbnail(url: photo.displayURL, size: CGSize(width: 64, height: 48))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(photo.fileName).fontWeight(.medium)
                            if model.isCleaning(photo.id) || photo.retouchLog != nil {
                                RetouchBadge(photo: photo)
                            } else if photo.edit != nil || photo.cleanups != nil {
                                Text("已修").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                    .tag(Optional(photo.id))
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var groupList: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
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
                retouchSummary(members)
            }
        }
        .padding(.vertical, 2)
    }

    /// 这一组正在修几张、初修完几张，不用点开组也能看到
    @ViewBuilder
    private func retouchSummary(_ members: [Photo]) -> some View {
        let working = members.filter { model.isCleaning($0.id) }.count
        let retouched = members.filter { $0.retouchLog != nil && !model.isCleaning($0.id) }.count
        if working > 0 || retouched > 0 {
            HStack(spacing: 6) {
                if working > 0 {
                    Label("修复中 \(working)", systemImage: "hourglass").foregroundStyle(.blue)
                }
                if retouched > 0 {
                    Label("已初修 \(retouched)", systemImage: "checkmark.seal.fill").foregroundStyle(.teal)
                }
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)
        }
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
