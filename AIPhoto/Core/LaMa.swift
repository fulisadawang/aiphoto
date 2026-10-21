import CoreGraphics
import CoreImage
import CoreML
import CryptoKit
import Foundation

/// 本机去杂物模型 LaMa（advimman/lama，Apache-2.0；Core ML 转换 john-rocky）。需求清单第 15 节。
/// 不打进安装包：第一次用时从本仓库的 Release 下载、校验、编译，存在 Application Support。
enum LaMaModel {
    static let downloadURL = URL(string: "https://github.com/fulisadawang/aiphoto/releases/download/models-lama-v1/LaMa.mlpackage.zip")!
    static let sha256 = "b57b8451a1a86c00aea52d75230fb5f49d3076eec67403192758c9d2b59c0e69"
    static let byteCount: Int64 = 196_237_256
    /// 模型输入输出固定 800×800
    static let side = 800

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIPhoto/models")
    }

    static var compiledURL: URL { directory.appendingPathComponent("LaMa.mlmodelc") }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: compiledURL.path) }

    enum InstallError: LocalizedError {
        case checksum
        case unzip
        case missingPackage
        var errorDescription: String? {
            switch self {
            case .checksum: "下载的模型文件校验不通过，可能没下完整，请重试"
            case .unzip: "解压模型失败"
            case .missingPackage: "压缩包里没有找到模型"
            }
        }
    }

    /// 下载 → 校验 SHA-256 → 解压 → 编译 → 放到固定位置。progress 为 0~1
    static func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("aiphoto-lama-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let zip = try await Downloader(expected: byteCount, progress: progress).download(downloadURL, to: work.appendingPathComponent("LaMa.mlpackage.zip"))
        guard try fileSHA256(zip) == sha256 else { throw InstallError.checksum }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw InstallError.unzip }
        let package = work.appendingPathComponent("LaMa.mlpackage")
        guard FileManager.default.fileExists(atPath: package.path) else { throw InstallError.missingPackage }

        let compiled = try await MLModel.compileModel(at: package)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: compiledURL)
        try FileManager.default.moveItem(at: compiled, to: compiledURL)
    }

    static func remove() throws {
        try FileManager.default.removeItem(at: compiledURL)
    }

    /// 只把小块交给本机：实拍对比（第 15 节第 1 阶段），面积占画面 0.6% 以上的推车、桌子、路人，
    /// 本机补出来是带彩色噪点的糊块，远不如 gpt-image-2；0.15% 以下的小物体干净。
    /// downscale 为局部图缩到 800 的倍数，缩得太多补出来发糊
    static func suits(maskFraction: Double, downscale: Double) -> Bool {
        maskFraction < 0.003 && downscale <= 1.5
    }

    private static func fileSHA256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 带进度的下载：系统下载完成时临时文件会被删，要在回调里先移走
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expected: Int64
    let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?

    init(expected: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expected = expected
        self.progress = progress
    }

    func download(_ url: URL, to destination: URL) async throws -> URL {
        self.destination = destination
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        progress(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let destination else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            continuation?.resume(throwing: URLError(.badServerResponse))
            continuation = nil
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume(returning: destination)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

/// 模型只加载一次（常驻约 300 MB），同一时间只跑一张，避免两个后台任务同时占内存
actor LaMaEngine {
    static let shared = LaMaEngine()
    private var model: MLModel?

    func fill(image: CGImage, mask: CGImage) async throws -> CGImage {
        let model = try loadedModel()
        let side = LaMaModel.side
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": try MLFeatureValue(cgImage: image, pixelsWide: side, pixelsHigh: side, pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
            "mask": try MLFeatureValue(cgImage: mask, pixelsWide: side, pixelsHigh: side, pixelFormatType: kCVPixelFormatType_OneComponent8, options: nil),
        ])
        let result = try await model.prediction(from: input)
        guard let buffer = result.featureValue(for: "output")?.imageBufferValue else { throw CleanupEngine.CleanupError.render }
        let output = CIImage(cvPixelBuffer: buffer)
        guard let cg = PhotoRenderer.context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: PhotoRenderer.sRGB),
              let resized = CleanupEngine.resize(cg, to: CGSize(width: image.width, height: image.height))
        else { throw CleanupEngine.CleanupError.render }
        return resized
    }

    /// 删除模型后释放
    func unload() { model = nil }

    private func loadedModel() throws -> MLModel {
        if let model { return model }
        let config = MLModelConfiguration()
        // 转换作者验证过的配置
        config.computeUnits = .all
        let loaded = try MLModel(contentsOf: LaMaModel.compiledURL, configuration: config)
        model = loaded
        return loaded
    }
}

struct LaMaInpainter: InpaintProvider {
    func inpaint(image: CGImage, mask: CGImage, prompt: String?) async throws -> CGImage {
        try await LaMaEngine.shared.fill(image: image, mask: mask)
    }
}
