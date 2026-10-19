import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let photo = model.selectedPhoto {
            Form {
                Section("选片") {
                    HStack {
                        Button { model.setDecision(.pick) } label: { Label("选用 P", systemImage: "checkmark") }
                            .tint(.green)
                        Button { model.setDecision(.reject) } label: { Label("淘汰 X", systemImage: "xmark") }
                            .tint(.red)
                        Button("取消 U") { model.setDecision(.none) }
                    }
                    .buttonStyle(.bordered)
                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= photo.rating ? "star.fill" : "star")
                                .foregroundStyle(.yellow)
                                .onTapGesture { model.setRating(star == photo.rating ? 0 : star) }
                        }
                    }
                }

                if let log = photo.retouchLog {
                    RetouchLogSection(log: log)
                }

                ShootingInfoSection(photo: photo)

                CleanupSection(photo: photo)

                EditSection(photo: photo)

                Section("AI 评价") {
                    if let ai = photo.ai {
                        LabeledContent("评分", value: "\(ai.score)")
                        LabeledContent("建议", value: ai.pick ? "推荐交付" : "不推荐")
                        Text(ai.reason)
                        if !ai.issues.isEmpty {
                            LabeledContent("问题", value: ai.issues.joined(separator: "、"))
                        }
                        if !ai.distractions.isEmpty {
                            LabeledContent("可去除的干扰物", value: ai.distractions.joined(separator: "、"))
                        }
                    } else {
                        Text("还没有 AI 评价。点工具栏「AI 选片」，每组本地评分最高的几张会送去评估。")
                            .foregroundStyle(.secondary)
                    }
                }

                if let analysis = photo.analysis {
                    Section("本地检测") {
                        LabeledContent("主体清晰度", value: String(format: "%.0f", photo.subjectSharpness ?? analysis.sharpness))
                        LabeledContent("主体定位", value: !analysis.faces.isEmpty ? "人脸" : analysis.subject != nil ? "人体" : "未识别到人（按同组人体位置或最清晰区域）")
                        LabeledContent("本地评分", value: String(format: "%.0f", photo.localScore))
                        LabeledContent("人脸", value: analysis.faces.isEmpty ? "未检测到" : "\(analysis.faces.count) 张")
                        ForEach(Array(analysis.faces.enumerated()), id: \.offset) { index, face in
                            LabeledContent("人脸 \(index + 1)") {
                                Text(faceSummary(face))
                                    .foregroundStyle(face.isBlinking ? .orange : .secondary)
                            }
                        }
                        LabeledContent("平均亮度", value: String(format: "%.0f%%", analysis.meanLuma * 100))
                        LabeledContent("高光溢出", value: String(format: "%.1f%%", analysis.highlightClip * 100))
                        LabeledContent("暗部死黑", value: String(format: "%.1f%%", analysis.shadowClip * 100))
                    }
                }

                Section("文件") {
                    LabeledContent("名称", value: photo.fileName)
                    LabeledContent("格式", value: photo.formatLabel)
                    if let date = photo.captureDate {
                        LabeledContent("拍摄时间", value: date.formatted(date: .abbreviated, time: .standard))
                    }
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([photo.rawURL, photo.renderedURL].compactMap { $0 })
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("未选择照片", systemImage: "photo")
        }
    }

    private func faceSummary(_ face: FaceInfo) -> String {
        var parts: [String] = []
        if let quality = face.quality { parts.append(String(format: "质量 %.2f", quality)) }
        parts.append(face.isBlinking ? "疑似闭眼" : "睁眼")
        return parts.joined(separator: " · ")
    }
}
