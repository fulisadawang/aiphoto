import Foundation

/// 选片进度保存在照片文件夹的 .aiphoto/session.json，重新打开时不用重复分析
enum SessionStore {
    static func fileURL(for folder: URL) -> URL {
        folder.appendingPathComponent(".aiphoto/session.json")
    }

    static func load(folder: URL) throws -> Session? {
        let url = fileURL(for: folder)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Session.self, from: Data(contentsOf: url))
    }

    static func save(_ session: Session, folder: URL) throws {
        let url = fileURL(for: folder)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(session).write(to: url, options: .atomic)
    }
}
