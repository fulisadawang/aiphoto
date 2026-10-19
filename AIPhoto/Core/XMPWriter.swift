import Foundation

/// 把选片结果写成 RAW 同名的 .xmp 附属文件，Lightroom / Capture One 导入时读取星级。
/// 已有 xmp（例如 Lightroom 写过修图参数）时只改星级字段，不覆盖其他内容
enum XMPWriter {
    enum XMPError: LocalizedError {
        case unrecognized(URL)
        var errorDescription: String? {
            switch self {
            case .unrecognized(let url): "无法识别已有的 XMP 文件，未修改：\(url.lastPathComponent)"
            }
        }
    }

    static func sidecarURL(forRAW raw: URL) -> URL {
        raw.deletingPathExtension().appendingPathExtension("xmp")
    }

    static func writeRating(_ rating: Int, forRAW raw: URL) throws {
        let url = sidecarURL(forRAW: raw)
        let text: String
        if FileManager.default.fileExists(atPath: url.path) {
            text = try updating(String(contentsOf: url, encoding: .utf8), rating: rating, url: url)
        } else {
            text = template(rating: rating)
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func updating(_ xml: String, rating: Int, url: URL) throws -> String {
        let attribute = #/xmp:Rating="-?\d+"/#
        if xml.contains(attribute) {
            return xml.replacing(attribute, with: "xmp:Rating=\"\(rating)\"")
        }
        let element = #/<xmp:Rating>-?\d+</xmp:Rating>/#
        if xml.contains(element) {
            return xml.replacing(element, with: "<xmp:Rating>\(rating)</xmp:Rating>")
        }
        guard let range = xml.range(of: "<rdf:Description") else { throw XMPError.unrecognized(url) }
        var insertion = " xmp:Rating=\"\(rating)\""
        if !xml.contains("xmlns:xmp=") {
            insertion = " xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"" + insertion
        }
        var result = xml
        result.insert(contentsOf: insertion, at: range.upperBound)
        return result
    }

    private static func template(rating: Int) -> String {
        """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Rating="\(rating)"/>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>

        """
    }
}
