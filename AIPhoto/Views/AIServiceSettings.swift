import SwiftUI

/// 设置 › AI 服务：新手只看状态和档位；连接、每件事用哪个模型、出错自动换收在高级设置里（需求清单第 14 节）
struct AIServiceSettings: View {
    @AppStorage(AppSettings.baseURLKey) private var baseURL = AppSettings.defaultBaseURL
    @AppStorage(AppSettings.autoFallbackKey) private var autoFallback = true
    @AppStorage(InpaintService.separateKey) private var imageSeparate = false
    @AppStorage(InpaintService.baseURLKey) private var imageBaseURL = AppSettings.defaultBaseURL
    @AppStorage("aiAdvancedExpanded") private var showAdvanced = false

    @State private var probe: ProbeState = .checking
    @State private var imageProbe: ProbeState?
    @State private var apiKey = ""
    @State private var keyStatus = ""
    @State private var imageKey = ""
    @State private var imageKeyStatus = ""
    /// 改模型后刷新档位显示（@AppStorage 分散在各行里）
    @State private var revision = 0

    enum ProbeState: Equatable {
        case checking
        case ok(Int)
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                statusCard
                tierSection
                advancedHeader
                if showAdvanced {
                    connectionSection
                    modelSection
                    fallbackSection
                }
            }
            .padding(20)
        }
        .frame(height: 560)
        .task { await check() }
        .onAppear {
            keyStatus = KeychainStore.isSaved(account: AppSettings.keychainAccount) ? "已保存" : ""
            imageKeyStatus = KeychainStore.isSaved(account: InpaintService.keychainAccount) ? "已保存" : ""
        }
    }

    // MARK: - 新手区

    private var statusCard: some View {
        HStack(spacing: 12) {
            IconTile(symbol: statusSymbol, tint: statusTint, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline)
                Text(statusDetail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("再检查一次") { Task { await check() } }
                .disabled(probe == .checking)
        }
        .padding(14)
        .groupBox()
    }

    private var statusSymbol: String {
        switch probe {
        case .checking: "ellipsis"
        case .ok: "checkmark"
        case .failed: "exclamationmark"
        }
    }

    private var statusTint: Color {
        switch probe {
        case .checking: .secondary
        case .ok: .green
        case .failed: .red
        }
    }

    private var statusTitle: String {
        switch probe {
        case .checking: "正在检查…"
        case .ok: "AI 可以用了"
        case .failed: "暂时连不上 AI"
        }
    }

    private var statusDetail: String {
        let viaMagpie = baseURL.contains("127.0.0.1:3425")
        switch probe {
        case .checking: return "正在连接 \(viaMagpie ? "本机 Magpie" : baseURL)"
        case .ok: return viaMagpie ? "通过本机 Magpie 连接 · 不需要填写任何东西" : "已连接 \(baseURL)"
        case .failed(let hint): return hint
        }
    }

    private var tierSection: some View {
        let _ = revision
        let current = ModelCatalog.currentTier
        return VStack(alignment: .leading, spacing: 8) {
            Text("你更在意哪一点？选一个，App 会给每件事配好合适的 AI")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 18)
            HStack(spacing: 10) {
                TierCard(symbol: "banknote", tint: .green, title: "省钱",
                         detail: "选片换成更便宜的 AI；找杂物和改图仍用准的", price: "未实测 · 花费看「用量」",
                         selected: current == .saving) { choose(.saving) }
                TierCard(symbol: "scalemass", tint: .accentColor, title: "推荐",
                         detail: "选片求快，找杂物和改图求准。大多数时候选它", price: "实测过 · 花费看「用量」",
                         selected: current == .recommended) { choose(.recommended) }
                TierCard(symbol: "diamond", tint: .purple, title: "效果优先",
                         detail: "每一步都用更强的 AI，更慢也更贵，适合重要交付", price: "未实测 · 花费看「用量」",
                         selected: current == .best) { choose(.best) }
            }
            if current == nil {
                Label("当前是自定义设置（在高级设置里改过）。点任一档位可恢复。", systemImage: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if current != .recommended {
                Label("这个档位的模型还没用你的照片测过；出错时会自动换回推荐模型。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func choose(_ tier: ModelCatalog.Tier) {
        ModelCatalog.apply(tier)
        revision += 1
    }

    private var advancedHeader: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.snappy) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                        .font(.caption.weight(.semibold))
                    Text("高级设置").foregroundStyle(.primary)
                    Text("· 一般不用动").foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if showAdvanced {
                Button {
                    ModelCatalog.resetToRecommended()
                    autoFallback = true
                    revision += 1
                } label: {
                    Label("恢复推荐", systemImage: "arrow.counterclockwise")
                }
                .controlSize(.small)
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Divider() }
        .padding(.top, 18)
    }

    // MARK: - 高级：连接

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("连接")
            VStack(spacing: 0) {
                SettingRow(symbol: "eye", tint: .blue, title: "看图的 AI", detail: "选片、找杂物、改图都用它") {
                    TextField("", text: $baseURL, prompt: Text(AppSettings.defaultBaseURL))
                        .labelsHidden()
                        .frame(width: 230)
                        .onSubmit { Task { await check() } }
                }
                Divider()
                SettingRow(symbol: "key", tint: .gray, title: "密钥", detail: keyStatus == "已保存" ? "已保存在钥匙串" : "用 Magpie 不需要") {
                    keyField(text: $apiKey, saved: keyStatus == "已保存") { saveKey(apiKey, account: AppSettings.keychainAccount) { keyStatus = $0; apiKey = "" } }
                }
                Divider()
                SettingRow(symbol: "paintbrush.pointed", tint: .purple, title: "画图的 AI", detail: "去杂物、重画、合成时用") {
                    Picker("", selection: $imageSeparate) {
                        Text("同上").tag(false)
                        Text("单独设置").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                }
                if imageSeparate {
                    Divider()
                    SettingRow(symbol: "link", tint: .purple, title: "画图地址", detail: imageProbeText) {
                        HStack(spacing: 6) {
                            TextField("", text: $imageBaseURL, prompt: Text(AppSettings.defaultBaseURL))
                                .labelsHidden()
                                .frame(width: 170)
                            Button("测试") { Task { await checkImage() } }
                        }
                    }
                    Divider()
                    SettingRow(symbol: "key", tint: .gray, title: "画图密钥", detail: imageKeyStatus == "已保存" ? "已保存在钥匙串" : "可选") {
                        keyField(text: $imageKey, saved: imageKeyStatus == "已保存") {
                            saveKey(imageKey, account: InpaintService.keychainAccount) { imageKeyStatus = $0; imageKey = "" }
                        }
                    }
                }
                Divider()
                SettingRow(symbol: probeRowSymbol, tint: statusTint, title: probeRowText, detail: nil) {
                    Button("测试连接") { Task { await check() } }
                        .disabled(probe == .checking)
                }
            }
            .groupBox()
        }
    }

    private var probeRowSymbol: String {
        if case .ok = probe { return "powerplug" }
        return "powerplug.portrait"
    }

    private var probeRowText: String {
        switch probe {
        case .checking: "正在连接…"
        case .ok(let count): "已连接 · 找到 \(count) 个模型"
        case .failed: "连不上，检查地址或先启动 Magpie"
        }
    }

    private var imageProbeText: String {
        switch imageProbe {
        case nil: "填好后点「测试」"
        case .checking?: "正在连接…"
        case .ok(let count)?: "已连接 · \(count) 个模型"
        case .failed(let hint)?: hint
        }
    }

    private func keyField(text: Binding<String>, saved: Bool, save: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            SecureField("", text: text, prompt: Text(saved ? "已保存" : "留空"))
                .labelsHidden()
                .frame(width: 160)
            Button("保存", action: save)
                .fixedSize()
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - 高级：模型

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("每件事用哪个模型 · 不确定就保持「推荐」")
            VStack(spacing: 0) {
                ForEach(Array(AIUse.allCases.enumerated()), id: \.element) { index, use in
                    if index > 0 { Divider() }
                    ModelRow(use: use, tint: Self.tint(use)) { revision += 1 }
                }
            }
            .groupBox()
            Text("标「未测试」的模型还没用你的照片测过，效果和价格不确定。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        }
    }

    static func tint(_ use: AIUse) -> Color {
        switch use {
        case .culling, .chat: .blue
        case .locate: .orange
        case .look: .green
        case .image: .purple
        }
    }

    // MARK: - 高级：出问题时

    private var fallbackSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("出问题时")
            SettingRow(symbol: "arrow.triangle.2.circlepath", tint: .red, title: "出错时自动换成推荐模型",
                       detail: "批量选片不会中途停下，换过的会在「用量」里标出") {
                Toggle("", isOn: $autoFallback).toggleStyle(.switch).labelsHidden()
            }
            .groupBox()
        }
    }

    // MARK: - 动作

    private func check() async {
        probe = .checking
        do {
            let key = try await KeychainStore.loadIfSaved(account: AppSettings.keychainAccount) ?? ""
            probe = .ok(try await ServiceProbe.modelCount(baseURL: baseURL, apiKey: key))
        } catch {
            probe = .failed(ServiceProbe.hint(error, baseURL: baseURL))
        }
    }

    private func checkImage() async {
        imageProbe = .checking
        do {
            let key = try await KeychainStore.loadIfSaved(account: InpaintService.keychainAccount) ?? ""
            imageProbe = .ok(try await ServiceProbe.modelCount(baseURL: imageBaseURL, apiKey: key))
        } catch {
            imageProbe = .failed(ServiceProbe.hint(error, baseURL: imageBaseURL))
        }
    }

    private func saveKey(_ value: String, account: String, done: (String) -> Void) {
        do {
            try KeychainStore.save(value.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
            done("已保存")
        } catch {
            done(error.localizedDescription)
        }
    }
}

// MARK: - 组件

/// 一件事的模型选择：分段按钮式的候选，推荐的带标签，最后是「自定义…」
private struct ModelRow: View {
    let use: AIUse
    let tint: Color
    let changed: () -> Void
    @AppStorage private var value: String
    @State private var custom = false
    @State private var draft = ""

    init(use: AIUse, tint: Color, changed: @escaping () -> Void) {
        self.use = use
        self.tint = tint
        self.changed = changed
        _value = AppStorage(wrappedValue: ModelCatalog.recommended(for: use), use.key)
    }

    private var options: [ModelOption] { ModelCatalog.options(for: use) }
    private var isCustom: Bool { custom || !options.contains { $0.id == value } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                IconTile(symbol: use.symbol, tint: tint, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(use.title)
                    Text(use.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
            }
            HStack(spacing: 2) {
                ForEach(options) { option in
                    chip(option.name, tag: option.recommended ? "推荐" : nil, note: option.recommended ? nil : option.note,
                         warning: option.discouraged, selected: !isCustom && value == option.id) {
                        custom = false
                        value = option.id
                        changed()
                    }
                }
                chip("自定义…", tag: nil, note: nil, warning: false, selected: isCustom) {
                    draft = options.contains { $0.id == value } ? "" : value
                    custom = true
                }
            }
            .padding(2)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .padding(.leading, 36)
            if isCustom {
                HStack(spacing: 6) {
                    TextField("", text: $draft, prompt: Text(use == .image ? "会画图的模型名" : "能看图的模型名，如 codex/gpt-6.1-sol"))
                        .labelsHidden()
                        .onSubmit(applyDraft)
                    Button("使用", action: applyDraft)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.leading, 36)
                if !value.isEmpty, !options.contains(where: { $0.id == value }) {
                    Text("正在使用：\(value)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 36)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { draft = isCustom ? value : "" }
    }

    private func applyDraft() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        value = text
        changed()
    }

    private func chip(_ title: String, tag: String?, note: String?, warning: Bool, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                if let tag {
                    Text(tag)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .foregroundStyle(Color.accentColor)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                }
                if let note {
                    Text(note).font(.system(size: 10)).foregroundStyle(warning ? .orange : .secondary)
                }
            }
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(selected ? .primary : .secondary)
            .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 0.5, y: 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TierCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    let price: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    IconTile(symbol: symbol, tint: tint, size: 26)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Divider()
                Text(price).font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            IconTile(symbol: symbol, tint: tint, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct IconTile: View {
    let symbol: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: size * 0.27))
    }
}

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.top, 16)
    }
}

private extension View {
    func groupBox() -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
    }
}
