import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @AppStorage(AppSettings.usdToCnyKey) private var usdToCny = 7.2
    @AppStorage(AppSettings.perGroupKey) private var perGroup = 6
    @AppStorage(AppSettings.blurKey) private var blurThreshold = 40.0
    @AppStorage(AppSettings.gapKey) private var maxGap = 3.0
    @AppStorage(AppSettings.distanceKey) private var maxDistance = 0.6



    var body: some View {
        TabView {
            cullingTab.tabItem { Label("选片", systemImage: "square.grid.2x2") }
            AIServiceSettings().tabItem { Label("AI 服务", systemImage: "sparkles") }
            usageTab.tabItem { Label("用量", systemImage: "chart.bar.xaxis") }
        }
        .frame(width: 560)
    }

    // MARK: - 选片

    private var cullingTab: some View {
        Form {
            Section {
                sliderRow("最大拍摄间隔", value: $maxGap, range: 0.5...15, step: 0.5, text: String(format: "%.1f 秒", maxGap))
                sliderRow("画面相似度阈值", value: $maxDistance, range: 0.2...1.2, step: 0.05, text: String(format: "%.2f", maxDistance))
            } header: {
                Text("连拍分组")
            } footer: {
                Text("间隔越长、阈值越大，越多照片会被归到同一组。")
            }

            Section {
                sliderRow("清晰度下限", value: $blurThreshold, range: 5...200, step: 5, text: String(format: "%.0f", blurThreshold))
            } header: {
                Text("模糊判断")
            } footer: {
                Text("主体清晰度低于该值标记为模糊；组内明显比最清晰那张差很多的也会标记。")
            }

            Section {
                LabeledContent("每组最多送审") {
                    HStack(spacing: 6) {
                        Text("\(perGroup) 张").monospacedDigit().foregroundStyle(.secondary)
                        Stepper("", value: $perGroup, in: 1...AIRanker.maxImagesPerRequest).labelsHidden()
                    }
                }
            } header: {
                Text("AI 选片")
            } footer: {
                Text("每组只把本地评分最高的几张发给 AI，张数越少越省钱。")
            }

            Section {
                Button("按当前参数重新分组") { model.regroup() }
                    .disabled(model.groups.isEmpty || model.isBusy)
            } footer: {
                Text("改了上面的分组参数后，点这里让当前文件夹按新参数重新分组。")
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }

    // MARK: - 用量

    private var usageTab: some View {
        Form {
            Section {
                LabeledContent("1 美元 =") {
                    HStack(spacing: 6) {
                        TextField("", value: $usdToCny, format: .number.precision(.fractionLength(2)))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("元")
                    }
                }
            } header: {
                Text("费用折算")
            } footer: {
                Text("AI 用量按 Magpie 的官方美元价折算成人民币显示。用量明细在菜单「选片 › AI 用量…」。")
            }
        }
        .formStyle(.grouped)
        .frame(height: 200)
    }

    // MARK: - 通用行

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range, step: step).frame(width: 200)
                Text(text).monospacedDigit().foregroundStyle(.secondary).frame(width: 56, alignment: .trailing)
            }
        }
    }
}
