import SwiftUI

/// 一键初修开始前：说明会做什么、选一个风格，然后全自动处理
struct RetouchStartSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var styleID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("一键初修 \(model.pickedCount) 张已选照片").font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                Label("自动调色：白平衡、曝光、高光阴影（手动修过的照片保留原调整）", systemImage: "wand.and.stars")
                Label("皮肤轻度柔化（检测到人脸时）", systemImage: "face.smiling")
                Label("去掉背景杂物：推车、杂物、电线、路人等；孩子手里的东西不动", systemImage: "eraser")
                Label("完成后给出总结，需要你看一眼的排在最前面", systemImage: "list.bullet.clipboard")
            }
            .foregroundStyle(.secondary)
            Picker("风格", selection: $styleID) {
                Text("不套用风格").tag(UUID?.none)
                ForEach(model.styles) { Text($0.name).tag(Optional($0.id)) }
            }
            Text("全程在后台进行，可以继续选片。去杂物每张约 30～60 秒。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("开始初修") {
                    model.startQuickRetouch(styleID: styleID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// 初修总结：需要看一眼的排前面，点任一条跳到该照片的修复前后对比
struct RetouchSummaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let logged = model.photos.values
            .filter { $0.retouchLog != nil }
            .sorted { ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id) }
        let review = logged.filter { $0.retouchLog?.needsReview == true }
        let done = logged.filter { $0.retouchLog?.needsReview != true }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("初修完成：\(logged.count) 张").font(.title3.bold())
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            List {
                if !review.isEmpty {
                    Section("需要你看一眼的（\(review.count) 张）") {
                        ForEach(review) { row($0, emphasize: true) }
                    }
                }
                Section("已自动处理（\(done.count) 张）") {
                    ForEach(done) { row($0, emphasize: false) }
                }
            }
        }
        .frame(width: 620, height: 560)
    }

    private func row(_ photo: Photo, emphasize: Bool) -> some View {
        let log = photo.retouchLog ?? RetouchLog()
        return Button {
            open(photo)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Thumbnail(url: photo.displayURL, size: CGSize(width: 72, height: 54))
                VStack(alignment: .leading, spacing: 3) {
                    Text(photo.fileName).fontWeight(.medium)
                    ForEach(log.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    ForEach(log.unfixable, id: \.self) { Label($0, systemImage: "xmark.octagon").foregroundStyle(.red) }
                    if !log.actions.isEmpty {
                        Text(log.actions.joined(separator: "，")).foregroundStyle(.secondary)
                    }
                    if !log.kept.isEmpty {
                        Text("保留：\(log.kept.joined(separator: "、"))").foregroundStyle(.tertiary)
                    }
                }
                .font(.callout)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func open(_ photo: Photo) {
        if let group = model.groups.first(where: { $0.photoIDs.contains(photo.id) }) {
            model.selectGroup(group.id, photoID: photo.id)
        }
        model.compareMode = true
        dismiss()
    }
}

/// 右侧：当前照片的初修记录
struct RetouchLogSection: View {
    let log: RetouchLog

    var body: some View {
        Section("初修记录") {
            ForEach(log.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            ForEach(log.unfixable, id: \.self) { Label($0, systemImage: "xmark.octagon").foregroundStyle(.red) }
            ForEach(log.kept, id: \.self) { Label("「\($0)」属于主体相关物品，没有去除", systemImage: "hand.raised") }
            ForEach(log.actions, id: \.self) { Label($0, systemImage: "checkmark") }
        }
        .font(.callout)
    }
}
