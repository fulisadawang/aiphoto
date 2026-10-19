import Foundation

/// 把连拍组打包送给看图模型，在组内挑出最值得交付的照片
struct AIRanker {
    let client: VisionChatClient

    /// 单次请求最多带的图片数，组不会被拆开
    static let maxImagesPerRequest = 8

    struct Candidate {
        let photoID: String
        let url: URL
        let groupID: Int
        let groupSize: Int
        let hints: [String]
    }

    /// 每组只取本地评分最高的前几张，按顺序装箱
    static func batches(groups: [PhotoGroup], photos: [String: Photo], perGroup: Int) -> [[Candidate]] {
        var batches: [[Candidate]] = []
        var current: [Candidate] = []
        let limit = max(1, min(perGroup, maxImagesPerRequest))
        for group in groups {
            let candidates = Culling.ranked(group, in: photos).prefix(limit).map { photo in
                var hints = photo.flags.map(\.label).sorted()
                if let faces = photo.analysis?.faces, !faces.isEmpty { hints.append("\(faces.count) 张人脸") }
                return Candidate(
                    photoID: photo.id, url: photo.displayURL,
                    groupID: group.id, groupSize: group.photoIDs.count, hints: hints
                )
            }
            if current.count + candidates.count > maxImagesPerRequest, !current.isEmpty {
                batches.append(current)
                current = []
            }
            current.append(contentsOf: candidates)
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    func rank(_ batch: [Candidate]) async throws -> [String: AIVerdict] {
        var content: [[String: Any]] = [[
            "type": "text",
            "text": "下面是 \(batch.count) 张照片，来自 \(Set(batch.map(\.groupID)).count) 个连拍组。",
        ]]
        for (index, candidate) in batch.enumerated() {
            guard let image = ImageLoader.image(at: candidate.url, maxPixel: 1280),
                  let jpeg = ImageLoader.jpegData(image, quality: 0.8)
            else { throw AnalyzerError.unreadable(candidate.url) }
            let hints = candidate.hints.isEmpty ? "无" : candidate.hints.joined(separator: "、")
            content.append([
                "type": "text",
                "text": "【P\(index + 1)】第 \(candidate.groupID) 组（该组共 \(candidate.groupSize) 张）。本地检测：\(hints)",
            ])
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"],
            ])
        }
        content.append(["type": "text", "text": Self.outputInstruction])

        let data = try await client.json(system: Self.systemPrompt, content: content)
        let response = try JSONDecoder().decode(Response.self, from: data)

        var verdicts: [String: AIVerdict] = [:]
        for item in response.photos {
            guard let number = Int(item.label.trimmingCharacters(in: .whitespaces).dropFirst()),
                  batch.indices.contains(number - 1)
            else { continue }
            verdicts[batch[number - 1].photoID] = AIVerdict(
                score: min(100, max(0, item.score)), pick: item.pick, reason: item.reason,
                issues: item.issues, distractions: item.distractions
            )
        }
        return verdicts
    }

    private struct Response: Decodable {
        struct Item: Decodable {
            let label: String
            let score: Int
            let pick: Bool
            let reason: String
            let issues: [String]
            let distractions: [String]
        }
        let photos: [Item]
    }

    static let systemPrompt = """
    你是一位资深的亲子与家庭纪实摄影选片师，帮摄影师从大量照片里挑出值得交付给客户的作品。

    评判标准（按重要性排序）：
    1. 情感与瞬间：真实的情绪、亲子互动、眼神交流、拥抱和肢体接触、自然的笑。纪实摄影里孩子哭闹、撒娇、被安抚的瞬间往往很珍贵，不要因为不是笑脸就淘汰。
    2. 主体清晰：孩子和家人的脸是否对焦清晰。背景虚化是正常的，主体的脸糊了才是问题；挥动的手有些动态模糊可以接受。
    3. 表情与眼睛：眨眼眨到一半、表情扭曲尴尬、嘴型奇怪的不推荐；闭眼大笑、熟睡的婴儿属于好照片。
    4. 多人照与全家福：每个人都要睁眼、脸不被遮挡，没有人扭头或表情怪异。
    5. 构图与光线：避免在关节等尴尬位置切掉肢体；后期能挽救的曝光问题不必淘汰。

    6. 可以后期去掉的干扰物（推车、杂物、电线、路人等）不影响是否推荐，只写进 distractions；只有挡住主体或无法修掉时才算问题。

    同一组照片是连拍或相似画面，通常只推荐 1～2 张最好的；如果组内其实是不同的瞬间，可以多推荐几张。
    每组独立判断，不要跨组比较：只要组内有一张主体清晰、表情不尴尬，就至少推荐这一组里最好的一张。只有一张的组，判断它本身是否值得交付。
    "本地检测"是算法给出的参考，可能有误，请以你看到的画面为准。
    """

    static let outputInstruction = """
    只输出一个 JSON 对象，不要其他文字，格式：
    {"photos":[{"label":"P1","score":80,"pick":true,"reason":"…","issues":["…"],"distractions":["…"]}]}
    每张照片一项：label（照片编号，如 P1）、score（0～100 的整数）、pick（是否推荐交付）、\
    reason（一句中文理由，20 字以内）、issues（存在的问题，没有则为空数组）、\
    distractions（画面里适合后期去除的干扰物，如插座、电线、杂物、路人、垃圾桶，没有则为空数组）。
    """
}
