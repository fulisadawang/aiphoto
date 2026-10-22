import SwiftUI

/// 对话改图：多轮对话，作用于当前照片。AI 的修改显示成结果卡片，最新一步可以单独撤销
struct ChatPanel: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    @State private var draft = ""
    @State private var customModel = ""
    @State private var showCustomModel = false
    @FocusState private var inputFocused: Bool

    private static let suggestions = ["再亮一点", "暖一点", "天空蓝一点", "去掉路人"]

    private var messages: [ChatMessage] { photo.chat ?? [] }
    private var thinking: AppModel.ChatThinking? { model.chatThinking[photo.id] }
    private var isThinking: Bool { thinking != nil }
    /// 只有最新一张结果卡片能撤销，与 ⌘Z 一步步往回撤一致
    private var latestStepID: UUID? { messages.last { $0.step != nil }?.id }
    private var currentModel: String { model.chatModelOverride ?? ModelCatalog.model(for: .chat) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty { hint }
                        ForEach(messages) { message($0).id($0.id) }
                        if let thinking {
                            thinkingRow(thinking)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: messages) { _, _ in
                    withAnimation { proxy.scrollTo("bottom") }
                }
                .onAppear { proxy.scrollTo("bottom") }
            }
            Divider()
            footer
        }
        .onAppear { inputFocused = true }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("对话改图", systemImage: "bubble.left.and.text.bubble.right")
                .font(.headline)
            Text(photo.fileName)
                .font(.caption)
                .foregroundStyle(.secondary)
            modelMenu
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    /// 在这里换的模型只对这次对话有效，换照片或重开 App 恢复设置里的模型
    private var modelMenu: some View {
        Menu {
            ForEach(ModelCatalog.options(for: .chat)) { option in
                Button {
                    model.chatModelOverride = option.id == ModelCatalog.model(for: .chat) ? nil : option.id
                } label: {
                    if option.id == currentModel { Image(systemName: "checkmark") }
                    Text(option.name + "（" + (option.claude ? "Claude · " : "") + option.note + "）")
                }
            }
            Divider()
            Button("其他模型…") {
                customModel = ""
                showCustomModel = true
            }
            if model.chatModelOverride != nil {
                Button("恢复设置里的模型") { model.chatModelOverride = nil }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                Text(ModelCatalog.displayName(currentModel, use: .chat))
                if currentModel == ModelCatalog.recommended(for: .chat) {
                    Text("推荐").modifier(TagStyle())
                } else if model.chatModelOverride != nil {
                    Text("仅本次").modifier(TagStyle(tint: .orange))
                }
            }
            .font(.caption)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .help("换一个模型来理解你的话，只对这次对话有效")
        .popover(isPresented: $showCustomModel, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("这次对话用的模型").font(.headline)
                TextField("能看图的模型名", text: $customModel)
                    .frame(width: 240)
                    .onSubmit(useCustomModel)
                HStack {
                    Spacer()
                    Button("取消") { showCustomModel = false }
                    Button("使用", action: useCustomModel)
                        .keyboardShortcut(.defaultAction)
                        .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
        }
    }

    private func useCustomModel() {
        let name = customModel.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.chatModelOverride = name
        showCustomModel = false
    }

    // MARK: - 消息

    private var hint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("对这张照片说一句话，AI 会帮你改，可以接着说继续调整。")
                .foregroundStyle(.secondary)
            Text("比如「亮一点，暖一点」「把右边的路人去掉」「天空蓝一点」。")
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func message(_ message: ChatMessage) -> some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.15), in: UnevenRoundedRectangle(
                        topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 4, topTrailingRadius: 12
                    ))
            }
            .font(.callout)
        } else if let step = message.step {
            ResultCard(message: message, step: step, isLatest: message.id == latestStepID)
        } else {
            HStack {
                Label {
                    Text(message.text).textSelection(.enabled)
                } icon: {
                    Image(systemName: message.isError ? "exclamationmark.triangle" : "text.bubble")
                        .foregroundStyle(message.isError ? .orange : .secondary)
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    message.isError ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 10)
                )
                Spacer(minLength: 30)
            }
        }
    }

    /// 正在做哪一步、已等多久；超过 3 分钟请求会自动放弃（AIRequest.timeout）
    private func thinkingRow(_ thinking: AppModel.ChatThinking) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(thinking.stage).font(.caption)
                    Text("已等 \(elapsedText(since: thinking.start, now: context.date)) · 一步超过 3 分钟会自动放弃")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer(minLength: 4)
                Button("取消") { model.cancelChat(photo.id) }
                    .controlSize(.small)
                    .help("不等了，这句话不执行，照片不改动")
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Self.suggestions, id: \.self) { text in
                        Button(text) {
                            draft = text
                            inputFocused = true
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 0.5))
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField("说说要怎么改…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit(send)
                    .padding(.vertical, 5)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.borderless)
                .disabled(isThinking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("发送（回车）")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.3), lineWidth: 0.5))
            HStack {
                Text("回车发送")
                Spacer()
                Text("⌘Z 撤销 · \\ 对比")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    private func send() {
        guard !isThinking else { return }
        let text = draft
        draft = ""
        model.sendChat(text)
    }
}

/// AI 的一步修改：做了什么、具体改动、后台进度，最新一步可以撤销
private struct ResultCard: View {
    @Environment(AppModel.self) private var model
    let message: ChatMessage
    let step: ChatStep
    let isLatest: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).font(.callout.weight(.medium))
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !step.changes.isEmpty {
                Text(step.changes.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let model = step.model {
                // 视觉修图是路由组，显示这次 Magpie 实际交给了哪个模型
                let claude = ModelCatalog.isClaude(model)
                Label(claude ? "由 \(model) 回答 · 这是 Claude" : "由 \(model) 回答", systemImage: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(claude ? Color.red : Color.secondary)
            }
            if step.pending > 0, !step.undone {
                jobProgress
            }
            if !step.undone {
                HStack(spacing: 6) {
                    if isLatest {
                        Button {
                            model.undoChatStep(message.id)
                        } label: {
                            Label("撤销这步", systemImage: "arrow.uturn.backward")
                        }
                    }
                    Button {
                        model.compareMode.toggle()
                    } label: {
                        Label(model.compareMode ? "关闭对比" : "对比", systemImage: "rectangle.split.2x1")
                    }
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .opacity(step.undone ? 0.55 : 1)
    }

    /// 后台去除 / 重画：排队还是在画、已等多久，可以停止
    private var jobProgress: some View {
        let jobs = model.chatJobs(message.id)
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(jobText(jobs, now: context.date))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if !jobs.isEmpty {
                    Button("停止") { model.stopChatJobs(message.id) }
                        .controlSize(.mini)
                        .help("还没做完的不做了，已完成的保留")
                }
            }
        }
    }

    private func jobText(_ jobs: [AppModel.CleanupJob], now: Date) -> String {
        if let started = jobs.compactMap(\.startedAt).min() {
            return "正在画，已等 \(elapsedText(since: started, now: now))（一般 30 秒左右，超过 3 分钟自动放弃）"
        }
        guard let first = jobs.first, let index = model.cleanupJobs.firstIndex(where: { $0.id == first.id }) else {
            return "后台处理中"
        }
        let ahead = model.cleanupJobs[..<index].filter { !$0.isRunning }.count
        return ahead > 0 ? "排队中，前面还有 \(ahead) 处" : "马上开始，等前面正在画的完成"
    }

    private var title: String {
        if step.undone { return "已撤销" }
        var parts: [String] = []
        if step.changedEdit { parts.append("已调色") }
        if step.jobs > 0 {
            if step.pending > 0 {
                parts.append("正在处理 \(step.pending) 处")
            } else {
                var result = ["完成 \(step.finished) 处"]
                if step.failed > 0 { result.append("失败 \(step.failed) 处") }
                if let stopped = step.stopped, stopped > 0 { result.append("停止 \(stopped) 处") }
                parts.append(result.count == 1 ? "已完成 \(step.finished) 处" : result.joined(separator: "，"))
            }
        }
        return parts.joined(separator: " · ")
    }

    private var symbol: String {
        if step.undone { return "arrow.uturn.backward.circle" }
        if step.pending > 0 { return "hourglass" }
        if step.failed > 0 { return "exclamationmark.triangle" }
        return step.jobs > 0 ? "wand.and.stars" : "slider.horizontal.3"
    }

    private var tint: Color {
        if step.undone { return .secondary }
        if step.failed > 0 { return .orange }
        return step.pending > 0 ? .purple : .green
    }
}

private struct TagStyle: ViewModifier {
    var tint: Color = .accentColor

    func body(content: Content) -> some View {
        content
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
    }
}
