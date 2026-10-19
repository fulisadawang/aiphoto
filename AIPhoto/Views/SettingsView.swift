import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    @AppStorage(AppSettings.modelKey) private var modelID = AppSettings.defaultModel
    @AppStorage(AppSettings.chatModelKey) private var chatModelID = AppSettings.defaultChatModel
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
        Form {
            Section("AI 选片模型") {
                TextField("接口地址", text: $selectBaseURL, prompt: Text(AppSettings.defaultBaseURL))
                SecureField("密钥", text: $apiKey)
                HStack {
                    Button("保存到钥匙串") { saveKey() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("删除") { deleteKey() }
                    Spacer()
                    Text(keyStatus).foregroundStyle(.secondary)
                }
                TextField("模型", text: $modelID, prompt: Text(AppSettings.defaultModel))
                TextField("对话改图模型", text: $chatModelID, prompt: Text(AppSettings.defaultChatModel))
                Text("OpenAI 兼容的 /chat/completions 接口，模型需要能看图。对话改图要框出物体位置，需要定位准的模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Stepper("每组最多送审 \(perGroup) 张", value: $perGroup, in: 1...AIRanker.maxImagesPerRequest)
                Text("每组只把本地评分最高的几张发给 AI，张数越少越省钱。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("去杂物服务") {
                Picker("服务", selection: $inpaintService) {
                    ForEach(InpaintService.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if inpaintService == InpaintService.openAICompatible.rawValue {
                    TextField("接口地址", text: $inpaintBaseURL, prompt: Text("http://127.0.0.1:3425/v1"))
                    TextField("模型", text: $inpaintModel, prompt: Text("留空：使用服务默认的图片模型"))
                    SecureField("密钥", text: $inpaintKey)
                    HStack {
                        Button("保存到钥匙串") { saveInpaintKey() }
                            .disabled(inpaintKey.trimmingCharacters(in: .whitespaces).isEmpty)
                        Spacer()
                        Text(inpaintKeyStatus).foregroundStyle(.secondary)
                    }
                    Text("调用 /images/edits 接口。模型必须能输出图片；对话模型（如 group/auto-auto）不出图，用 Magpie 时建议留空。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("连拍分组") {
                LabeledContent("最大拍摄间隔") {
                    Slider(value: $maxGap, in: 0.5...15, step: 0.5) { Text("") }
                    Text(String(format: "%.1f 秒", maxGap)).monospacedDigit().frame(width: 60)
                }
                LabeledContent("画面相似度阈值") {
                    Slider(value: $maxDistance, in: 0.2...1.2, step: 0.05) { Text("") }
                    Text(String(format: "%.2f", maxDistance)).monospacedDigit().frame(width: 60)
                }
                Text("阈值越大，越多不同画面会被归到同一组。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("模糊判断") {
                LabeledContent("清晰度下限") {
                    Slider(value: $blurThreshold, in: 5...200, step: 5) { Text("") }
                    Text(String(format: "%.0f", blurThreshold)).monospacedDigit().frame(width: 60)
                }
                Text("主体清晰度低于该值标记为模糊；组内明显比最清晰那张差很多的也会标记。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("按新参数重新分组当前文件夹") { model.regroup() }
                    .disabled(model.groups.isEmpty || model.isBusy)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 720)
        .onAppear(perform: loadKeyStatus)
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
