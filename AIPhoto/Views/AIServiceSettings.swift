import SwiftUI

/// 设置 › AI 服务：新手只看状态和「视觉修图」组的说明；连接、每件事用哪个模型收在高级设置里（需求清单第 14、18 节）
struct AIServiceSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.baseURLKey) private var baseURL = AppSettings.defaultBaseURL
    @AppStorage(InpaintService.separateKey) private var imageSeparate = false
    @AppStorage(InpaintService.baseURLKey) private var imageBaseURL = AppSettings.defaultBaseURL
    @AppStorage("aiAdvancedExpanded") private var showAdvanced = false

    @State private var probe: ProbeState = .checking
    @State private var imageProbe: ProbeState?
    @State private var apiKey = ""
    @State private var keyStatus = ""
    @State private var imageKey = ""
    @State private var imageKeyStatus = ""
    /// 改模型后刷新显示（@AppStorage 分散在各行里）
    @State private var revision = 0
    /// 最近 7 天 Magpie 实际用到的模型；nil 为还没读到
    @State private var recentModels: [UsageReport.Line]?

    enum ProbeState: Equatable {
        case checking
        case ok(Int)
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                statusCard
                groupSection
                advancedHeader
                if showAdvanced {
                    connectionSection
                    modelSection
                }
            }
            .padding(20)
        }
        .frame(height: 560)
        .task {
            await check()
            await loadRecentModels()
        }
        .onAppear {
            keyStatus = SecretStore.isSaved(account: AppSettings.secretAccount) ? "已保存" : ""
            imageKeyStatus = SecretStore.isSaved(account: InpaintService.secretAccount) ? "已保存" : ""
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

    /// 出错换模型由 Magpie 的「视觉修图」组按顺序完成，App 不再分档、不再自己重试（需求清单第 18 节）
    private var groupSection: some View {
        let _ = revision
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel("用的是哪个 AI")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    IconTile(symbol: "square.stack.3d.up", tint: .accentColor, size: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(ModelCatalog.isAllRecommended ? "Magpie 的「视觉修图」组" : "自定义（高级设置里改过）").font(.headline)
                        Text("AI 选片、找杂物、对话改图默认都用它：按你在 Magpie 里排的顺序用模型，出错自动换下一个。想换顺序或去掉某个模型，在 Magpie 的「视觉修图」里改。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let ids = ServiceModels.shared.ids, !ids.contains(ModelCatalog.visionRetouch),
                   AIUse.allCases.contains(where: { ModelCatalog.stored($0) == ModelCatalog.visionRetouch }) {
                    Label("这台电脑连的 Magpie 里没有「视觉修图」组：在 Magpie 里建一个，或在下面「高级设置」里给每件事选一个模型。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                recentModelsView
            }
            .padding(14)
            .groupBox()
        }
    }

    @ViewBuilder
    private var recentModelsView: some View {
        if let recentModels {
            if recentModels.isEmpty {
                Text("最近 7 天还没有 AI 请求").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("最近 7 天实际用到的模型").font(.caption).foregroundStyle(.secondary)
                    ForEach(recentModels.prefix(6)) { line in
                        let claude = ModelCatalog.isClaude(line.id)
                        HStack {
                            Text(line.id)
                            if claude {
                                Text("Claude · 你定过选片不用").font(.caption2).foregroundStyle(.red)
                            }
                            Spacer()
                            Text("\(line.calls) 次").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        .foregroundStyle(claude ? .red : .primary)
                    }
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在读取最近用到的模型…").font(.caption).foregroundStyle(.secondary)
            }
        }
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
                SettingRow(symbol: "key", tint: .gray, title: "密钥", detail: keyStatus == "已保存" ? "已保存在本机" : "用 Magpie 不需要") {
                    keyField(text: $apiKey, saved: keyStatus == "已保存") { saveKey(apiKey, account: AppSettings.secretAccount) { keyStatus = $0; apiKey = "" } }
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
                    SettingRow(symbol: "key", tint: .gray, title: "画图密钥", detail: imageKeyStatus == "已保存" ? "已保存在本机" : "可选") {
                        keyField(text: $imageKey, saved: imageKeyStatus == "已保存") {
                            saveKey(imageKey, account: InpaintService.secretAccount) { imageKeyStatus = $0; imageKey = "" }
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
            SectionLabel("每件事用哪个模型 · 不确定就保持「视觉修图」")
            VStack(spacing: 0) {
                ForEach(Array(AIUse.allCases.enumerated()), id: \.element) { index, use in
                    if index > 0 { Divider() }
                    ModelRow(use: use, tint: Self.tint(use)) { revision += 1 }
                }
            }
            .groupBox()
            Text("列表是当前连接的服务里实际有的模型。选单个模型时，出错不会自动换下一个。")
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

    // MARK: - 动作

    private func loadRecentModels() async {
        let report = try? await model.usageReport(since: Date().addingTimeInterval(-7 * 24 * 3600)).0
        recentModels = (report?.byModel ?? []).sorted { $0.calls > $1.calls }
    }

    private func check() async {
        probe = .checking
        do {
            let key = try await SecretStore.loadIfSaved(account: AppSettings.secretAccount) ?? ""
            let ids = try await ServiceProbe.models(baseURL: baseURL, apiKey: key)
            ServiceModels.shared.set(ids)
            probe = .ok(ids.count)
        } catch {
            ServiceModels.shared.set(nil)
            probe = .failed(ServiceProbe.hint(error, baseURL: baseURL))
        }
    }

    private func checkImage() async {
        imageProbe = .checking
        do {
            let key = try await SecretStore.loadIfSaved(account: InpaintService.secretAccount) ?? ""
            let ids = try await ServiceProbe.models(baseURL: imageBaseURL, apiKey: key)
            ServiceModels.shared.set(ids, image: true)
            imageProbe = .ok(ids.count)
        } catch {
            ServiceModels.shared.set(nil, image: true)
            imageProbe = .failed(ServiceProbe.hint(error, baseURL: imageBaseURL))
        }
    }

    private func saveKey(_ value: String, account: String, done: (String) -> Void) {
        do {
            try SecretStore.save(value.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
            done("已保存")
        } catch {
            done(error.localizedDescription)
        }
    }
}

// MARK: - 组件

/// 一件事的模型选择：下拉菜单（视觉修图 + 组里的各个模型 + 自定义…）
private struct ModelRow: View {
    let use: AIUse
    let tint: Color
    let changed: () -> Void
    @AppStorage private var value: String
    @State private var custom = false
    @State private var draft = ""

    private static let customTag = "__custom__"

    init(use: AIUse, tint: Color, changed: @escaping () -> Void) {
        self.use = use
        self.tint = tint
        self.changed = changed
        _value = AppStorage(wrappedValue: ModelCatalog.recommended(for: use), use.key)
    }

    private var options: [ModelOption] { ModelCatalog.options(for: use) }
    private var isCustom: Bool { custom || !options.contains { $0.id == value } }
    private var selectedOption: ModelOption? { options.first { $0.id == value } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                IconTile(symbol: use.symbol, tint: tint, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(use.title)
                    Text(use.detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { isCustom ? Self.customTag : value },
                    set: { newValue in
                        if newValue == Self.customTag {
                            draft = isCustom ? value : ""
                            custom = true
                        } else {
                            custom = false
                            value = newValue
                            changed()
                        }
                    }
                )) {
                    ForEach(options) { option in
                        Text(label(option)).tag(option.id)
                    }
                    Divider()
                    Text("自定义…").tag(Self.customTag)
                }
                .labelsHidden()
                .frame(width: 220)
            }
            if let option = selectedOption, !isCustom, let warning = warning(option) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.leading, 36)
            }
            if isCustom {
                HStack(spacing: 6) {
                    TextField("", text: $draft, prompt: Text(use == .image ? "会画图的模型名" : "能看图的模型名，如 codex/gpt-6-luna"))
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
                    // 换了电脑或服务后，原来选的模型在这个服务里可能没有，一用就会报错
                    if let ids = ServiceModels.shared.available(for: use), !ids.contains(value) {
                        Label("当前连接的服务里没有这个模型，用的时候会出错；请从列表里重新选", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .padding(.leading, 36)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { draft = isCustom ? value : "" }
    }

    private func label(_ option: ModelOption) -> String {
        option.recommended ? "\(option.name)（推荐）" : "\(option.name) · \(option.note)"
    }

    private func warning(_ option: ModelOption) -> String? {
        if option.claude, use == .culling || use == .look { return "这是 Claude，你定过选片不用 Claude" }
        return nil
    }

    private func applyDraft() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        value = text
        changed()
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
