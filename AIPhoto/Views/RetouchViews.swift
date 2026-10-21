import SwiftUI

/// 一键初修开始前：说明会做什么，选预设、写本场诉求，然后全自动处理
struct RetouchStartSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var presetID: UUID?
    @State private var note = ""
    /// 在这个窗口上再弹出预设管理；从主界面弹会被当前窗口挡住
    @State private var showManager = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("一键初修 \(model.pickedCount) 张已选照片").font(.title3.bold())
            VStack(alignment: .leading, spacing: 6) {
                Label("自动调色：每张按自身光线校正白平衡和曝光，再叠加预设和本场诉求", systemImage: "wand.and.stars")
                Label("去掉背景杂物：推车、杂物、电线、路人等；孩子手里的东西和你要求保留的不动", systemImage: "eraser")
                Label("完成后给出总结，需要你看一眼的排在最前面", systemImage: "list.bullet.clipboard")
            }
            .foregroundStyle(.secondary)
            HStack {
                Picker("预设", selection: $presetID) {
                    Text("不用预设").tag(UUID?.none)
                    ForEach(model.presets) { Text($0.name).tag(Optional($0.id)) }
                }
                Button("管理…") { showManager = true }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("本场诉求（可选）").font(.callout)
                NoteEditor(text: $note)
                Text(presetID == nil && note.isEmpty
                     ? "不选预设也不写诉求：自动调色，手动修过的照片保留原调整。"
                     : "选了预设或写了诉求：全部已选照片按此重新调色（手动修过的也会重做，可 ⌘Z 撤回），去杂物结果保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("全程在后台进行，可以继续选片。去杂物每张约 30～60 秒。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("开始初修") {
                    model.startQuickRetouch(presetID: presetID, note: note)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { selectPreset(model.defaultPresetID) }
        .sheet(isPresented: $showManager) { PresetManagerSheet().environment(model) }
        .onChange(of: presetID) { old, new in
            // 换预设时，如果诉求还是上一个预设的原文，换成新预设的描述
            let oldNote = model.presets.first { $0.id == old }?.note ?? ""
            if note == oldNote { note = model.presets.first { $0.id == new }?.note ?? "" }
        }
    }

    private func selectPreset(_ id: UUID?) {
        presetID = id
        note = model.presets.first { $0.id == id }?.note ?? ""
    }
}

/// 初修总结：需要看一眼的排前面，点任一条跳到该照片的修复前后对比
struct RetouchSummaryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var retouchCost: String?

    var body: some View {
        let logged = model.photos.values
            .filter { $0.retouchLog != nil }
            .sorted { ($0.captureDate ?? .distantPast, $0.id) < ($1.captureDate ?? .distantPast, $1.id) }
        let review = logged.filter { $0.retouchLog?.needsReview == true }
        let done = logged.filter { $0.retouchLog?.needsReview != true }

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(model.lastBatchOnlyCleanup ? "去杂物完成" : "初修完成")：\(logged.count) 张").font(.title3.bold())
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(16)
            if let cost = retouchCost {
                Label(cost, systemImage: "yensign.circle")
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            if let summary = model.lastLookSummary {
                Label("AI 对本场诉求的理解：\(summary)", systemImage: "text.bubble")
                    .font(.callout)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
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
        .task {
            // 出图结果在 Magpie 里落账稍慢，稍等一下再取
            guard let window = model.lastRetouchWindow else { return }
            try? await Task.sleep(for: .seconds(2))
            guard let (report, _) = try? await model.usageReport(since: window.start, until: window.end) else { return }
            retouchCost = "本次初修调用 AI \(report.total.calls) 次，约 \(UsageView.yuan(report.total.cost))"
                + (report.total.unpriced > 0 ? "（\(report.total.unpriced) 次未计价）" : "")
        }
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
