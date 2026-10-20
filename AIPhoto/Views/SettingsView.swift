import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @AppStorage(AppSettings.modelKey) private var modelID = AppSettings.defaultModel
    @AppStorage(AppSettings.chatModelKey) private var chatModelID = AppSettings.defaultChatModel
    @AppStorage(AppSettings.usdToCnyKey) private var usdToCny = 7.2
    @AppStorage(AppSettings.baseURLKey) private var selectBaseURL = AppSettings.defaultBaseURL
    @AppStorage(AppSettings.perGroupKey) private var perGroup = 6
    @AppStorage(AppSettings.blurKey) private var blurThreshold = 40.0
    @AppStorage(AppSettings.gapKey) private var maxGap = 3.0
    @AppStorage(AppSettings.distanceKey) private var maxDistance = 0.6

    @AppStorage(InpaintService.serviceKey) private var inpaintService = InpaintService.openAICompatible.rawValue
    @AppStorage(InpaintService.baseURLKey) private var inpaintBaseURL = "http://127.0.0.1:3425/v1"
    @AppStorage(InpaintService.modelKey) private var inpaintModel = ""

    @State private var apiKey = ""
    @State private var keyStatus = ""
    @State private var inpaintKey = ""
    @State private var inpaintKeyStatus = ""

    var body: some View {
        TabView {
            cullingTab.tabItem { Label("选片", systemImage: "square.grid.2x2") }
            serviceTab.tabItem { Label("AI 服务", systemImage: "sparkles") }
            usageTab.tabItem { Label("用量", systemImage: "chart.bar.xaxis") }
        }
        .frame(width: 560)
        .onAppear(perform: loadKeyStatus)
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

    // MARK: - AI 服务

    private var serviceTab: some View {
        Form {
            Section {
                TextField("接口地址", text: $selectBaseURL, prompt: Text(AppSettings.defaultBaseURL))
                keyRow(text: $apiKey, status: keyStatus, save: saveKey, delete: deleteKey)
            } header: {
                Text("看图模型服务")
            } footer: {
                Text("OpenAI 兼容的 /chat/completions 接口。用本机 Magpie 时不需要密钥。")
            }

            Section {
                TextField("AI 选片、找杂物", text: $modelID, prompt: Text(AppSettings.defaultModel))
                TextField("对话改图", text: $chatModelID, prompt: Text(AppSettings.defaultChatModel))
            } header: {
                Text("模型")
            } footer: {
                Text("模型需要能看图；对话改图要框出物体位置，需要定位准的模型。不要用 group/auto-auto，它会被路由到 Claude。")
            }

            Section {
                Picker("服务", selection: $inpaintService) {
                    ForEach(InpaintService.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if inpaintService == InpaintService.openAICompatible.rawValue {
                    TextField("接口地址", text: $inpaintBaseURL, prompt: Text("http://127.0.0.1:3425/v1"))
                    TextField("图片模型", text: $inpaintModel, prompt: Text("留空：使用服务默认的图片模型"))
                    keyRow(text: $inpaintKey, status: inpaintKeyStatus, save: saveInpaintKey, delete: nil)
                }
            } header: {
                Text("去杂物 / 重画")
            } footer: {
                Text("调用 /images/edits 接口，模型必须能输出图片。用 Magpie 时图片模型建议留空。")
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

    private func keyRow(text: Binding<String>, status: String, save: @escaping () -> Void, delete: (() -> Void)?) -> some View {
        LabeledContent("密钥") {
            HStack(spacing: 8) {
                SecureField("", text: text, prompt: Text(status == "已保存" ? "已保存在钥匙串" : "可选"))
                    .labelsHidden()
                    .frame(width: 180)
                Button("保存") { save() }
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
                if let delete, status == "已保存" {
                    Button("删除", role: .destructive) { delete() }
                }
            }
        }
    }

    private func loadKeyStatus() {
        keyStatus = KeychainStore.isSaved(account: AppSettings.keychainAccount) ? "已保存" : "未设置"
        inpaintKeyStatus = KeychainStore.isSaved(account: InpaintService.keychainAccount) ? "已保存" : "未设置"
    }

    private func saveInpaintKey() {
        do {
            try KeychainStore.save(inpaintKey.trimmingCharacters(in: .whitespacesAndNewlines), account: InpaintService.keychainAccount)
            inpaintKey = ""
            inpaintKeyStatus = "已保存"
        } catch {
            inpaintKeyStatus = error.localizedDescription
        }
    }

    private func saveKey() {
        do {
            try KeychainStore.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: AppSettings.keychainAccount)
            apiKey = ""
            keyStatus = "已保存"
        } catch {
            keyStatus = error.localizedDescription
        }
    }

    private func deleteKey() {
        do {
            try KeychainStore.delete(account: AppSettings.keychainAccount)
            keyStatus = "未设置"
        } catch {
            keyStatus = error.localizedDescription
        }
    }
}
