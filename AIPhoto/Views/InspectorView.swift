import SwiftUI

/// 右侧面板：顶部切换「选片 / 修图」。选片只放判断用的信息；修图用左侧竖向工具栏，一次只显示一个工具
struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.composite {
            CompositePanel(session: session)
        } else if let photo = model.selectedPhoto {
            // 只修图：照片已经选好，只有修图
            if model.shootMode == .editOnly {
                EditingInspector(photo: photo)
            } else {
                VStack(spacing: 0) {
                    modePicker
                    Divider()
                    switch model.inspectorMode {
                    case .culling: CullingInspector(photo: photo)
                    case .editing: EditingInspector(photo: photo)
                    }
                }
            }
        } else {
            ContentUnavailableView("未选择照片", systemImage: "photo")
        }
    }

    /// 系统分段控件在 macOS 上不会撑满宽度，自己画一个满宽的两段切换
    private var modePicker: some View {
        HStack(spacing: 2) {
            modeButton("选片", symbol: "checkmark.rectangle.stack", mode: .culling)
            modeButton("修图", symbol: "wand.and.stars", mode: .editing)
        }
        .padding(3)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func modeButton(_ title: String, symbol: String, mode: InspectorMode) -> some View {
        let selected = model.inspectorMode == mode
        return Button {
            model.inspectorMode = mode
        } label: {
            Label(title, systemImage: symbol)
                .font(.callout.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 28)
                .foregroundStyle(selected ? .primary : .secondary)
                .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 选片模式

private struct CullingInspector: View {
    @Environment(AppModel.self) private var model
    let photo: Photo

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    decisionButton("选用", key: "P", symbol: "checkmark", tint: .green, decision: .pick)
                    decisionButton("淘汰", key: "X", symbol: "xmark", tint: .red, decision: .reject)
                    decisionButton("取消", key: "U", symbol: "arrow.uturn.backward", tint: .secondary, decision: .none)
                }
                HStack {
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= photo.rating ? "star.fill" : "star")
                                .font(.title3)
                                .foregroundStyle(.yellow)
                                .onTapGesture { model.setRating(star == photo.rating ? 0 : star) }
                        }
                    }
                    Spacer()
                    Button {
                        model.showTool(.chat)
                    } label: {
                        Label("对话改图", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .buttonStyle(.borderless)
                    .help("用一句话修改这张照片（切到修图模式）")
                }
            }

            if !photo.flags.isEmpty || !(photo.ai?.issues ?? []).isEmpty {
                Section("需要注意") {
                    ForEach(photo.flags.sorted { $0.rawValue < $1.rawValue }, id: \.self) { flag in
                        Label(flag.label, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    ForEach(photo.ai?.issues ?? [], id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    }
                }
            }

            Section("AI 评价") {
                if let ai = photo.ai {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(ai.score)").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(ai.pick ? "推荐交付" : "不推荐")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(ai.pick ? .green : .secondary)
                        Spacer()
                    }
                    Text(ai.reason)
                    if !ai.distractions.isEmpty {
                        LabeledContent("可去除的干扰物", value: ai.distractions.joined(separator: "、"))
                    }
                } else {
                    Text("还没有 AI 评价。点工具栏「AI 选片」，每组本地评分最高的几张会送去评估。")
                        .foregroundStyle(.secondary)
                }
            }

            ShootingInfoSection(photo: photo)

            Section {
                DisclosureGroup("本地检测与文件") {
                    if let analysis = photo.analysis {
                        LabeledContent("主体清晰度", value: String(format: "%.0f", photo.subjectSharpness ?? analysis.sharpness))
                        LabeledContent("主体定位", value: !analysis.faces.isEmpty ? "人脸" : analysis.subject != nil ? "人体" : "未识别到人")
                        LabeledContent("本地评分", value: String(format: "%.0f", photo.localScore))
                        LabeledContent("人脸", value: analysis.faces.isEmpty ? "未检测到" : "\(analysis.faces.count) 张")
                        ForEach(Array(analysis.faces.enumerated()), id: \.offset) { index, face in
                            LabeledContent("人脸 \(index + 1)") {
                                Text(Self.faceSummary(face)).foregroundStyle(face.isBlinking ? .orange : .secondary)
                            }
                        }
                        LabeledContent("平均亮度", value: String(format: "%.0f%%", analysis.meanLuma * 100))
                        LabeledContent("高光溢出", value: String(format: "%.1f%%", analysis.highlightClip * 100))
                        LabeledContent("暗部死黑", value: String(format: "%.1f%%", analysis.shadowClip * 100))
                    }
                    LabeledContent("文件", value: "\(photo.fileName) · \(photo.formatLabel)")
                    if let date = photo.captureDate {
                        LabeledContent("拍摄时间", value: date.formatted(date: .abbreviated, time: .standard))
                    }
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([photo.rawURL, photo.renderedURL].compactMap { $0 })
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func decisionButton(_ title: String, key: String, symbol: String, tint: Color, decision: Decision) -> some View {
        let selected = photo.decision == decision && decision != .none
        return Button {
            model.setDecision(decision)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.title3.weight(.semibold))
                Text("\(title) \(key)").font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(selected ? .white : tint)
            .background(selected ? tint : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    static func faceSummary(_ face: FaceInfo) -> String {
        var parts: [String] = []
        if let quality = face.quality { parts.append(String(format: "质量 %.2f", quality)) }
        parts.append(face.isBlinking ? "疑似闭眼" : "睁眼")
        return parts.joined(separator: " · ")
    }
}

// MARK: - 修图模式

private struct EditingInspector: View {
    @Environment(AppModel.self) private var model
    let photo: Photo

    var body: some View {
        HStack(spacing: 0) {
            toolRail
            Divider()
            VStack(spacing: 0) {
                toolContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let histogram = model.histogram {
                    Divider()
                    HistogramView(histogram: histogram)
                        .frame(height: 56)
                        .padding(10)
                }
            }
        }
    }

    private var toolRail: some View {
        VStack(spacing: 6) {
            ForEach(EditTool.allCases) { tool in
                let selected = model.editTool == tool
                Button {
                    model.editTool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 16, weight: .medium))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(selected ? Color.white : Color.secondary)
                        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            // 初修有需要检查的问题时，只在图标上提示，不自动切换
                            if tool == .log, photo.retouchLog?.needsReview == true {
                                Circle().fill(.red).frame(width: 8, height: 8).offset(x: 1, y: -1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tool.title)
                .accessibilityLabel(tool.title)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private var toolContent: some View {
        switch model.editTool {
        case .adjust:
            Form { EditSection(photo: photo) }.formStyle(.grouped)
        case .portrait:
            Form { PortraitSection(photo: photo) }
                .formStyle(.grouped)
                .task(id: photo.id) { model.ensureFaceShapes(photo.id) }
        case .cleanup:
            Form { CleanupSection(photo: photo) }.formStyle(.grouped)
        case .composite:
            Form { CompositeEntrySection() }.formStyle(.grouped)
        case .chat:
            ChatPanel(photo: photo)
        case .log:
            if let log = photo.retouchLog {
                Form { RetouchLogSection(log: log) }.formStyle(.grouped)
            } else {
                ContentUnavailableView("这张还没有初修记录", systemImage: "list.bullet.clipboard",
                                       description: Text("一键初修后，每张做了什么、哪里需要看一眼会记在这里。"))
            }
        }
    }
}
