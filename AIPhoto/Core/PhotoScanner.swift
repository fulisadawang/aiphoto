import Foundation

enum PhotoScanner {
    static let rawExtensions: Set<String> = [
        "3fr", "arw", "cr2", "cr3", "crw", "dng", "erf", "iiq", "kdc", "mef", "mos", "mrw",
        "nef", "nrw", "orf", "pef", "raf", "raw", "rw2", "rwl", "sr2", "srf", "srw", "x3f",
    ]
    static let renderedExtensions: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]

    /// 递归扫描文件夹，把同名的 RAW 与 JPG 合并成一张照片
    static func scan(folder: URL) -> [Photo] {
        let root = folder.resolvingSymlinksInPath().path
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var photos: [String: Photo] = [:]
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            let isRaw = rawExtensions.contains(ext)
            guard isRaw || renderedExtensions.contains(ext) else { continue }

            let path = url.resolvingSymlinksInPath().deletingPathExtension().path
            let id = String(path.dropFirst(root.count + 1))
            var photo = photos[id] ?? Photo(id: id)
            if isRaw {
                photo.rawURL = url
            } else {
                photo.renderedURL = url
            }
            photos[id] = photo
        }
        return Array(photos.values)
    }
}
