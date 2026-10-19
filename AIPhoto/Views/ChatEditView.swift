import SwiftUI

/// 右侧面板里的入口：点开后整列换成对话
struct ChatEntrySection: View {
    @Environment(AppModel.self) private var model
    let photo: Photo

    var body: some View {
        Section("对话改图") {
            Button {
                model.chatPanelOpen = true
            } label: {
                Label("用一句话修改这张照片…", systemImage: "bubble.left.and.text.bubble.right")
            }
            if let last = photo.chat?.last {
                Text(last.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// 对话改图：多轮对话，作用于当前照片
struct ChatPanel: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var messages: [ChatMessage] { photo.chat ?? [] }
    private var isThinking: Bool { model.chattingPhotoIDs.contains(photo.id) }
    private var pendingJobs: Int { model.cleanupJobs.filter { $0.photoID == photo.id && $0.fromChat }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("对话改图", systemImage: "bubble.left.and.text.bubble.right").font(.headline)
                Spacer()
                Button { model.chatPanelOpen = false } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("关闭对话，回到修图面板")
            }
            .padding([.horizontal, .top], 12)
            Text(photo.fileName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if messages.isEmpty { hint }
                        ForEach(messages) { bubble($0).id($0.id) }
                        if isThinking {
                            statusRow("正在理解你的意思…")
                        }
                        if pendingJobs > 0 {
                            statusRow("后台处理中 \(pendingJobs) 处，可以继续说或看别的照片")
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom") }
                }
                .onAppear { proxy.scrollTo("bottom") }
            }

            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("说说要怎么改，回车发送", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(isThinking || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("发送")
            }
            .padding(12)
        }
        .onAppear { inputFocused = true }
    }

    private var hint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("对这张照片说一句话，AI 会帮你改，可以接着说继续调整。").foregroundStyle(.secondary)
            ForEach(["亮一点，暖一点", "把右边的路人去掉", "天空蓝一点", "脸瘦一点，自然些"], id: \.self) { example in
                Button(example) { draft = example; inputFocused = true }
                    .buttonStyle(.link)
            }
            Text("每一步都可以 ⌘Z 撤销；按 \\ 对比修改前后。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 30) }
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    isUser ? Color.accentColor.opacity(0.25) : message.isError ? Color.red.opacity(0.18) : Color.secondary.opacity(0.15),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            if !isUser { Spacer(minLength: 30) }
        }
        .font(.callout)
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func send() {
        guard !isThinking else { return }
        let text = draft
        draft = ""
        model.sendChat(text)
    }
}
