import CoreGraphics
import Foundation
import ImageIO

/// 从佳能 MakerNote 的 AFInfo2（标签 0x0026）读出拍摄时实际合焦的对焦框。
/// ImageIO 不解析这部分厂商数据，这里直接读文件字节：JPG 在 Exif 的 MakerNote 里，CR3 在 CMT3 盒子里。
/// 已用佳能 R6 Mark II 实拍核对过坐标；其他品牌或读不到时返回空数组
enum AFPointReader {
    /// 返回合焦对焦框，归一化坐标（原点左上），已按方向标记转正
    static func focusedAreas(at url: URL) -> [CGRect] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let bytes = [UInt8](data.prefix(4 * 1024 * 1024))
        let ext = url.pathExtension.lowercased()
        if ext == "cr3" {
            guard let start = find(Array("CMT3".utf8), in: bytes) else { return [] }
            // 盒子类型后紧跟 TIFF 头，MakerNote 的 IFD 偏移相对于这个 TIFF 头
            return parse(makerNoteTIFF: start + 4, in: bytes, orientation: orientation(of: url))
        }
        guard let exif = find(Array("Exif\0\0".utf8), in: bytes) else { return [] }
        return parseJPEGExif(tiff: exif + 6, in: bytes, orientation: orientation(of: url))
    }

    private static func orientation(of url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return 1 }
        return props[kCGImagePropertyOrientation] as? Int ?? 1
    }

    private struct Reader {
        let bytes: [UInt8]
        let tiff: Int
        let little: Bool

        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            let a = Int(bytes[offset]), b = Int(bytes[offset + 1])
            return little ? a | b << 8 : a << 8 | b
        }

        func u32(_ offset: Int) -> Int? {
            guard let low = u16(little ? offset : offset + 2), let high = u16(little ? offset + 2 : offset) else { return nil }
            return low | high << 16
        }

        /// 读 IFD，返回 标签 → (类型, 数量, 值或偏移所在位置)
        func entries(at ifd: Int) -> [Int: (type: Int, count: Int, valueOffset: Int)] {
            guard let count = u16(tiff + ifd) else { return [:] }
            var result: [Int: (Int, Int, Int)] = [:]
            for index in 0..<count {
                let entry = tiff + ifd + 2 + index * 12
                guard let tag = u16(entry), let type = u16(entry + 2), let n = u32(entry + 4) else { continue }
                result[tag] = (type, n, entry + 8)
            }
            return result
        }

        /// 读 SHORT / SSHORT 数组（AFInfo2 全是 16 位）
        func shorts(_ entry: (type: Int, count: Int, valueOffset: Int)) -> [Int]? {
            let start = entry.count * 2 <= 4 ? entry.valueOffset : u32(entry.valueOffset).map { tiff + $0 }
            guard let start else { return nil }
            return (0..<entry.count).compactMap { u16(start + $0 * 2) }
        }
    }

    private static func parseJPEGExif(tiff: Int, in bytes: [UInt8], orientation: Int) -> [CGRect] {
        guard tiff + 8 <= bytes.count else { return [] }
        let reader = Reader(bytes: bytes, tiff: tiff, little: bytes[tiff] == 0x49)
        guard let ifd0 = reader.u32(tiff + 4),
              let exifPointer = reader.entries(at: ifd0)[0x8769],
              let exifIFD = reader.u32(exifPointer.valueOffset),
              let makerNote = reader.entries(at: exifIFD)[0x927C],
              let makerIFD = reader.u32(makerNote.valueOffset)
        else { return [] }
        return areas(reader: reader, makerIFD: makerIFD, orientation: orientation)
    }

    private static func parse(makerNoteTIFF tiff: Int, in bytes: [UInt8], orientation: Int) -> [CGRect] {
        guard tiff + 8 <= bytes.count else { return [] }
        let reader = Reader(bytes: bytes, tiff: tiff, little: bytes[tiff] == 0x49)
        guard let ifd = reader.u32(tiff + 4) else { return [] }
        return areas(reader: reader, makerIFD: ifd, orientation: orientation)
    }

    /// AFInfo2：[大小, 区域模式, 点数 n, 有效点数, 相机图宽, 高, AF 图宽, 高, 宽×n, 高×n, X×n, Y×n, 合焦位图…]。
    /// X/Y 是有符号数，以画面中心为原点，Y 向上为正
    private static func areas(reader: Reader, makerIFD: Int, orientation: Int) -> [CGRect] {
        guard let entry = reader.entries(at: makerIFD)[0x26], let v = reader.shorts(entry), v.count > 8 else { return [] }
        let n = v[2], valid = v[3]
        let width = Double(v[6] > 0 ? v[6] : v[4]), height = Double(v[7] > 0 ? v[7] : v[5])
        guard n > 0, valid > 0, width > 0, height > 0, v.count >= 8 + 4 * n + (n + 15) / 16 else { return [] }
        func signed(_ value: Int) -> Double { Double(value >= 0x8000 ? value - 0x10000 : value) }
        let inFocus = Array(v[(8 + 4 * n)..<(8 + 4 * n + (n + 15) / 16)])

        return (0..<min(n, valid)).compactMap { i -> CGRect? in
            // 合焦位图全为 0 时（部分机型只记录选中点）仍显示有效点
            let focused = inFocus.allSatisfy { $0 == 0 } || inFocus[i / 16] & (1 << (i % 16)) != 0
            guard focused else { return nil }
            let w = Double(v[8 + i]), h = Double(v[8 + n + i])
            let cx = width / 2 + signed(v[8 + 2 * n + i])
            let cy = height / 2 - signed(v[8 + 3 * n + i])
            let rect = CGRect(x: (cx - w / 2) / width, y: (cy - h / 2) / height, width: w / width, height: h / height)
            return oriented(rect, orientation: orientation)
        }
    }

    /// 传感器坐标（横向）转到方向转正后的显示坐标
    private static func oriented(_ r: CGRect, orientation: Int) -> CGRect {
        switch orientation {
        case 3: return CGRect(x: 1 - r.maxX, y: 1 - r.maxY, width: r.width, height: r.height)
        case 6: return CGRect(x: 1 - r.maxY, y: r.minX, width: r.height, height: r.width)
        case 8: return CGRect(x: r.minY, y: 1 - r.maxX, width: r.height, height: r.width)
        default: return r
        }
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        for i in 0...(bytes.count - pattern.count) where bytes[i] == pattern[0] {
            if Array(bytes[i..<(i + pattern.count)]) == pattern { return i }
        }
        return nil
    }
}
