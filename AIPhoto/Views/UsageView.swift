import SwiftUI

/// AI 用量：本地日志按场次、功能记账，费用和实际模型取自 Magpie 的记录
struct UsageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var period = Period.week
    @State private var breakdown = Breakdown.purpose
    @State private var report: UsageReport?
    @State private var quotas: [MagpieUsage.Quota] = []
    @State private var error: String?

    enum Period: String, CaseIterable, Identifiable {
        case today = "今天", week = "近 7 天", month = "近 30 天"
        var id: String { rawValue }
        var since: Date {
            switch self {
            case .today: Calendar.current.startOfDay(for: Date())
            case .week: Date().addingTimeInterval(-7 * 86400)
            case .month: Date().addingTimeInterval(-30 * 86400)
            }
        }
    }

    enum Breakdown: String, CaseIterable, Identifiable {
        case purpose = "按功能", shoot = "按场次", model = "按模型"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let error {
                    ContentUnavailableView("读不到用量记录", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if let report {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if report.claudeCalls > 0 { claudeWarning(report.claudeCalls) }
                            stats(report)
                            breakdownCard(report)
                            if !quotas.isEmpty { quotaCard }
                        }
                        .padding(20)
                    }
                } else {
                    ProgressView("正在读取 Magpie 的用量记录…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 720, height: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: period) { await load() }
    }

    private var header: some View {
        HStack {
            Label("AI 用量", systemImage: "chart.bar.xaxis").font(.title3.weight(.semibold))
            Spacer()
            Picker("", selection: $period) {
                ForEach(Period.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "info.circle").foregroundStyle(.tertiary)
            Text("按 Magpie 官方价折算，1 美元 = \(String(format: "%.2f", AppSettings.usdToCny)) 元（设置里可改）。订阅账号不按次扣费，金额表示「按量付费大约要花多少」。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func load() async {
        report = nil
        error = nil
        do {
            let result = try await model.usageReport(since: period.since)
            report = result.0
            quotas = result.1
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - 概览

    static func callDetail(_ line: UsageReport.Line) -> String {
        var parts: [String] = []
        if line.failures > 0 { parts.append("失败 \(line.failures) 次") }
        return parts.isEmpty ? "全部成功" : parts.joined(separator: " · ")
    }

    private func stats(_ report: UsageReport) -> some View {
        let total = report.total
        return HStack(spacing: 12) {
            StatCard(title: "折算花费", value: Self.yuan(total.cost), detail: total.unpriced > 0 ? "\(total.unpriced) 次未计价" : nil, tint: .accentColor, prominent: true)
            StatCard(title: "调用次数", value: "\(total.calls)", detail: Self.callDetail(total), tint: total.failures > 0 ? .orange : .green)
            StatCard(title: "平均每次", value: total.calls > 0 ? Self.yuan(total.cost / Double(total.calls)) : "—", detail: nil, tint: .secondary)
            StatCard(title: "Token", value: Self.tokens(total.inputTokens + total.outputTokens), detail: "输入 \(Self.tokens(total.inputTokens)) · 输出 \(Self.tokens(total.outputTokens))", tint: .secondary)
        }
    }

    private func claudeWarning(_ count: Int) -> some View {
        Label("有 \(count) 次请求实际用的是 Claude，请到设置里检查模型", systemImage: "exclamationmark.octagon.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 明细

    private func breakdownCard(_ report: UsageReport) -> some View {
        let lines: [UsageReport.Line] = switch breakdown {
        case .purpose: report.byPurpose
        case .shoot: report.byShoot
        case .model: report.byModel
        }
        let maxCost = lines.map(\.cost).max() ?? 0
        return Card {
            HStack {
                Text("明细").font(.headline)
                Spacer()
                Picker("", selection: $breakdown) {
                    ForEach(Breakdown.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
            }
            if lines.isEmpty {
                Text("这段时间没有调用 AI")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                        if index > 0 { Divider().padding(.leading, 4) }
                        BreakdownRow(line: line, share: maxCost > 0 ? line.cost / maxCost : 0)
                    }
                }
            }
        }
    }

    // MARK: - 额度

    private var quotaCard: some View {
        Card {
            Text("订阅账号额度").font(.headline)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top), GridItem(.flexible(), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(Array(quotas.enumerated()), id: \.offset) { _, quota in
                    QuotaTile(quota: quota)
                }
            }
        }
    }

    static func yuan(_ usd: Double) -> String {
        let value = usd * AppSettings.usdToCny
        return value < 0.01 && value > 0 ? "< ¥0.01" : String(format: "¥%.2f", value)
    }

    static func tokens(_ count: Int) -> String {
        count >= 10000 ? String(format: "%.1f万", Double(count) / 10000) : "\(count)"
    }
}

/// 圆角卡片容器
private struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let detail: String?
    let tint: Color
    var prominent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: prominent ? 26 : 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(prominent ? tint : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail ?? " ")
                .font(.caption2)
                .foregroundStyle(tint == .secondary ? .secondary : tint)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
    }
}

/// 一行明细：名称、按花费占比的横条、次数和金额
private struct BreakdownRow: View {
    let line: UsageReport.Line
    let share: Double

    private var isClaude: Bool { line.id.lowercased().contains("claude") }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(line.id).font(.callout.weight(.medium)).lineLimit(1)
                    if isClaude { Text("Claude").font(.caption2.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1).background(.red, in: Capsule()) }
                }
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(isClaude ? Color.red : Color.accentColor)
                            .frame(width: max(4, geometry.size.width * share))
                    }
                }
                .frame(height: 6)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(line.unpriced == line.calls ? "未计价" : UsageView.yuan(line.cost))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                Text(line.failures > 0 ? "\(line.calls) 次 · 失败 \(line.failures)" : "\(line.calls) 次")
                    .font(.caption)
                    .foregroundStyle(line.failures > 0 ? .orange : .secondary)
                    .monospacedDigit()
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }
}

/// 一个订阅账号：每个额度窗口一根进度条
private struct QuotaTile: View {
    let quota: MagpieUsage.Quota

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(quota.name ?? quota.provider ?? "").font(.callout.weight(.semibold))
                Spacer()
                if let plan = quota.plan {
                    Text(plan).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
            let windows = quota.windows ?? []
            if windows.isEmpty {
                Text("没有额度信息").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                let used = min(100, max(0, window.used ?? 0))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(window.name ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(window.display ?? String(format: "%.0f%%", used)).font(.caption).monospacedDigit()
                    }
                    // 系统进度条在 macOS 上不吃 tint，自己画，用颜色表示紧张程度
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule()
                                .fill(used > 80 ? Color.red : used > 50 ? Color.orange : Color.green)
                                .frame(width: max(3, geometry.size.width * used / 100))
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
