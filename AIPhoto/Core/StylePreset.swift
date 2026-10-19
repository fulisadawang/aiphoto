import CoreGraphics
import CoreImage
import Foundation

/// 从"原图 → 修好的成片"样片对里学到的调色风格，存为 3D LUT
struct StylePreset: Codable, Identifiable {
    let id: UUID
    var name: String
    var createdAt: Date
    var pairCount: Int
    /// 立方体边长
    var dimension: Int
    /// RGBA 浮点，按 CIColorCube 要求 r 变化最快、b 最慢
    var cube: [Float]

    func apply(to image: CIImage, strength: Double) -> CIImage {
        let data = cube.withUnsafeBufferPointer { Data(buffer: $0) }
        let styled = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": data,
            "inputColorSpace": PhotoRenderer.sRGB,
        ])
        guard strength < 1 else { return styled }
        return styled.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: image,
            kCIInputTimeKey: 1 - max(0, strength),
        ])
    }
}

/// 风格预设存在 ~/Library/Application Support/AIPhoto/styles/，所有文件夹共用
final class StyleStore: @unchecked Sendable {
    static let shared = StyleStore()

    private let lock = NSLock()
    private var cache: [UUID: StylePreset]?

    var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIPhoto/styles")
    }

    func all() throws -> [StylePreset] {
        try loaded().values.sorted { $0.createdAt < $1.createdAt }
    }

    func preset(_ id: UUID) -> StylePreset? {
        lock.lock()
        defer { lock.unlock() }
        return cache?[id]
    }

    func save(_ preset: StylePreset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(preset).write(to: fileURL(preset.id), options: .atomic)
        lock.lock()
        cache?[preset.id] = preset
        lock.unlock()
    }

    func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: fileURL(id))
        lock.lock()
        cache?[id] = nil
        lock.unlock()
    }

    @discardableResult
    func loaded() throws -> [UUID: StylePreset] {
        lock.lock()
        defer { lock.unlock() }
        if let cache { return cache }
        var presets: [UUID: StylePreset] = [:]
        if FileManager.default.fileExists(atPath: directory.path) {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.pathExtension == "json" {
                let preset = try JSONDecoder().decode(StylePreset.self, from: Data(contentsOf: url))
                presets[preset.id] = preset
            }
        }
        cache = presets
        return presets
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}

enum StyleLearner {
    static let dimension = 17
    /// 样本太少的格子向原色回退，避免学到噪声
    static let minSamplesPerCell = 4.0

    struct Pair {
        let original: URL
        let finished: URL
    }

    enum LearnError: LocalizedError {
        case noPairs
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .noPairs: "两个文件夹里没有找到同名的照片对（按文件名配对，扩展名可以不同）"
            case .unreadable(let name): "无法读取：\(name)"
            }
        }
    }

    /// 按文件名（不含扩展名）配对，原图可以是 RAW 或 JPG
    static func pairs(originals: URL, finished: URL) throws -> [Pair] {
        let extensions = PhotoScanner.rawExtensions.union(PhotoScanner.renderedExtensions)
        func index(_ folder: URL) throws -> [String: URL] {
            var map: [String: URL] = [:]
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            where extensions.contains(url.pathExtension.lowercased()) {
                let key = url.deletingPathExtension().lastPathComponent.lowercased()
                // 同名同时有 RAW 和 JPG 时优先 RAW：修图底图就是 RAW 解码
                if map[key] == nil || PhotoScanner.rawExtensions.contains(url.pathExtension.lowercased()) {
                    map[key] = url
                }
            }
            return map
        }
        let left = try index(originals), right = try index(finished)
        let result = left.compactMap { key, url in right[key].map { Pair(original: url, finished: $0) } }
        guard !result.isEmpty else { throw LearnError.noPairs }
        return result.sorted { $0.original.lastPathComponent < $1.original.lastPathComponent }
    }

    /// 两张图缩到同样尺寸逐像素对应，把每个原色格子里的成片颜色取平均，得到 LUT
    static func learn(name: String, pairs: [Pair], progress: (Int) -> Void) throws -> StylePreset {
        let n = dimension
        var sums = [Double](repeating: 0, count: n * n * n * 3)
        var counts = [Double](repeating: 0, count: n * n * n)

        for (index, pair) in pairs.enumerated() {
            // 原图是 RAW 时按修图底图解码，学到的风格才能和预览、导出对上
            guard let before = ImageLoader.editBase(at: pair.original, maxPixel: 384) else {
                throw LearnError.unreadable(pair.original.lastPathComponent)
            }
            guard let after = ImageLoader.image(at: pair.finished, maxPixel: 384) else {
                throw LearnError.unreadable(pair.finished.lastPathComponent)
            }
            // 成片被裁切过时画面对不上，跳过该对
            let ratioBefore = Double(before.width) / Double(before.height)
            let ratioAfter = Double(after.width) / Double(after.height)
            guard abs(ratioBefore - ratioAfter) < 0.02 else { continue }

            let size = (width: 256, height: max(1, Int(256 / ratioBefore)))
            let a = try rgbBytes(before, size: size), b = try rgbBytes(after, size: size)
            for pixel in stride(from: 0, to: a.count, by: 4) {
                let r = Int((Double(a[pixel]) / 255 * Double(n - 1)).rounded())
                let g = Int((Double(a[pixel + 1]) / 255 * Double(n - 1)).rounded())
                let bl = Int((Double(a[pixel + 2]) / 255 * Double(n - 1)).rounded())
                let cell = (bl * n + g) * n + r
                sums[cell * 3] += Double(b[pixel]) / 255
                sums[cell * 3 + 1] += Double(b[pixel + 1]) / 255
                sums[cell * 3 + 2] += Double(b[pixel + 2]) / 255
                counts[cell] += 1
            }
            progress(index + 1)
        }

        // 每个格子：样本足够用平均值；不足时按样本量与"邻近格子平均偏移"混合，完全没有样本就沿用邻近偏移
        var offsets = [Double](repeating: .nan, count: n * n * n * 3)
        for cell in 0..<(n * n * n) where counts[cell] > 0 {
            let identity = identityColor(cell)
            for c in 0..<3 { offsets[cell * 3 + c] = sums[cell * 3 + c] / counts[cell] - identity[c] }
        }
        let filled = fillOffsets(offsets, counts: counts)

        var cube = [Float](repeating: 1, count: n * n * n * 4)
        for cell in 0..<(n * n * n) {
            let identity = identityColor(cell)
            let weight = min(1, counts[cell] / minSamplesPerCell)
            for c in 0..<3 {
                let own = counts[cell] > 0 ? offsets[cell * 3 + c] : 0
                let offset = weight * own + (1 - weight) * filled[cell * 3 + c]
                cube[cell * 4 + c] = Float(min(1, max(0, identity[c] + offset)))
            }
        }
        return StylePreset(id: UUID(), name: name, createdAt: Date(), pairCount: pairs.count, dimension: n, cube: cube)
    }

    private static func identityColor(_ cell: Int) -> [Double] {
        let n = dimension
        return [Double(cell % n), Double(cell / n % n), Double(cell / (n * n))].map { $0 / Double(n - 1) }
    }

    /// 用逐步扩大的邻域平均来补全稀疏格子的偏移
    private static func fillOffsets(_ offsets: [Double], counts: [Double]) -> [Double] {
        let n = dimension
        var result = offsets.map { $0.isNaN ? 0 : $0 }
        for cell in 0..<(n * n * n) where counts[cell] < minSamplesPerCell {
            let r = cell % n, g = cell / n % n, b = cell / (n * n)
            for radius in 1...4 {
                var sum = [0.0, 0.0, 0.0], weight = 0.0
                for db in -radius...radius {
                    for dg in -radius...radius {
                        for dr in -radius...radius {
                            let (rr, gg, bb) = (r + dr, g + dg, b + db)
                            guard (0..<n).contains(rr), (0..<n).contains(gg), (0..<n).contains(bb) else { continue }
                            let other = (bb * n + gg) * n + rr
                            guard counts[other] >= minSamplesPerCell else { continue }
                            for c in 0..<3 { sum[c] += offsets[other * 3 + c] * counts[other] }
                            weight += counts[other]
                        }
                    }
                }
                if weight > 0 {
                    for c in 0..<3 { result[cell * 3 + c] = sum[c] / weight }
                    break
                }
            }
        }
        return result
    }

    private static func rgbBytes(_ image: CGImage, size: (width: Int, height: Int)) throws -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: size.width * size.height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: size.width, height: size.height, bitsPerComponent: 8,
                bytesPerRow: size.width * 4, space: PhotoRenderer.sRGB,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            return true
        }
        guard drawn else { throw AnalyzerError.context }
        return buffer
    }
}
