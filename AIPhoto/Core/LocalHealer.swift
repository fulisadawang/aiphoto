import CoreGraphics

/// 本机修复：调用 Compositor 的修复画笔（spot_heal）和内容识别填充（patch_fill），C 代码见 Vendor/Compositor。
/// 输入都是同尺寸的局部图和灰度蒙版（白色为要修的区域），在 8 位预乘 RGBA 上原地处理
enum LocalHealer {
    /// spot_heal 的三种模式，数值与 HealPixels.h 一致
    enum HealMode: Int32 {
        /// 按内容补：逐像素从周围重建，边缘和纹理能延续进来
        case contentAware = 0
        /// 生成纹理：从边缘平滑铺过来，再加上和周围一样的颗粒
        case texture = 1
        /// 借附近最像的一块：找周围一圈最吻合的一块皮肤搬过来，再按边缘明暗过渡
        case proximity = 2
    }

    /// 内容识别填充：从局部图其余部分找最像的纹理补上蒙版区域。
    /// exclude 白色的地方（局部图里的人）不拿来借纹理：patch_fill 不会从透明像素取材，先把它们设成透明，补完再还原
    static func fill(_ image: CGImage, hole mask: CGImage, exclude: CGImage? = nil, seed: UInt32 = 1) -> CGImage? {
        let excluded = exclude.map(grayPixels)
        return process(image, mask: mask) { pixels, stride, coverage, width, height in
            if let excluded, excluded.count == width * height {
                for index in 0..<(width * height) where excluded[index] > 127 && coverage[index] == 0 {
                    pixels.advanced(by: index * 4).update(repeating: 0, count: 4)
                }
            }
            // 返回 1 才是补好了；0 表示局部图里没有可借的纹理
            return patch_fill(pixels, stride, coverage, width, Int32(width), Int32(height), seed) == 1
        }
    }

    /// 修复画笔：蒙版灰度即修复强度
    static func heal(_ image: CGImage, coverage mask: CGImage, mode: HealMode, seed: UInt32 = 1) -> CGImage? {
        process(image, mask: mask) { pixels, stride, coverage, width, height in
            spot_heal(pixels, coverage, width, height, stride, 1, mode.rawValue, seed) == 0
        }
    }

    private static func process(
        _ image: CGImage, mask: CGImage,
        _ run: (UnsafeMutablePointer<UInt8>, Int, UnsafePointer<UInt8>, Int, Int) -> Bool
    ) -> CGImage? {
        let width = image.width, height = image.height
        guard mask.width == width, mask.height == height,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: PhotoRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let coverage = grayPixels(mask)
        let original = Array(UnsafeBufferPointer(start: pixels, count: width * height * 4))
        let ok = coverage.withUnsafeBufferPointer { run(pixels, width * 4, $0.baseAddress!, width, height) }
        guard ok else { return nil }
        // 蒙版外一律还原成原图（包括为了不借纹理而临时设成透明的人）
        for index in 0..<(width * height) where coverage[index] == 0 {
            for channel in 0..<4 { pixels[index * 4 + channel] = original[index * 4 + channel] }
        }
        return context.makeImage()
    }

}

/// 判断杂物周围是纹理（草地、地面、墙面、天空）还是有结构（窗框、栏杆、门）：
/// 看周围一圈里有多少像素处在成片的同一方向边缘上（结构张量的方向一致性）。草地的边缘方向杂乱，窗框是成片的直线
enum StructureMeter {
    /// 方向一致性高于这个值、且边缘够强的像素算「成片直线」
    static let coherenceThreshold: Float = 0.75
    /// 边缘强度门槛（亮度 0～1 的梯度平方和，经 5×5 平均）；低于它算平坦，不算结构
    static let energyThreshold: Float = 0.002

    /// 蒙版里白色像素的个数
    static func count(_ mask: CGImage) -> Int {
        grayPixels(mask).reduce(0) { $0 + ($1 > 127 ? 1 : 0) }
    }

    /// 洞四周一圈（宽为洞最长边的一半，至少 3 像素）里成片直线像素的比例
    static func ringStructure(_ image: CGImage, hole: CGImage) -> Double {
        let width = image.width, height = image.height
        guard hole.width == width, hole.height == height else { return 1 }
        let luma = grayPixels(image).map { Float($0) / 255 }
        let isHole = grayPixels(hole).map { $0 > 127 }

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where isHole[y * width + x] {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return 0 }
        let ringRadius = max(3, max(maxX - minX, maxY - minY) / 2)

        // 洞向外扩 ringRadius（方形膨胀，先行后列），减去洞本身就是一圈
        var nearRow = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            var last = -Int.max / 2
            var next = [Int](repeating: Int.max / 2, count: width)
            var upcoming = Int.max / 2
            for x in stride(from: width - 1, through: 0, by: -1) {
                if isHole[y * width + x] { upcoming = x }
                next[x] = upcoming
            }
            for x in 0..<width {
                if isHole[y * width + x] { last = x }
                nearRow[y * width + x] = x - last <= ringRadius || next[x] - x <= ringRadius
            }
        }
        var ring = [Bool](repeating: false, count: width * height)
        for x in 0..<width {
            var last = -Int.max / 2
            var next = [Int](repeating: Int.max / 2, count: height)
            var upcoming = Int.max / 2
            for y in stride(from: height - 1, through: 0, by: -1) {
                if nearRow[y * width + x] { upcoming = y }
                next[y] = upcoming
            }
            for y in 0..<height {
                if nearRow[y * width + x] { last = y }
                let index = y * width + x
                ring[index] = !isHole[index] && (y - last <= ringRadius || next[y] - y <= ringRadius)
            }
        }

        // 结构张量：梯度外积，5×5 平均
        var jxx = [Float](repeating: 0, count: width * height)
        var jyy = jxx, jxy = jxx
        for y in 1..<max(1, height - 1) {
            for x in 1..<max(1, width - 1) {
                let index = y * width + x
                let gx = (luma[index + 1] - luma[index - 1]) / 2
                let gy = (luma[index + width] - luma[index - width]) / 2
                jxx[index] = gx * gx; jyy[index] = gy * gy; jxy[index] = gx * gy
            }
        }
        jxx = boxBlur(jxx, width: width, height: height, radius: 2)
        jyy = boxBlur(jyy, width: width, height: height, radius: 2)
        jxy = boxBlur(jxy, width: width, height: height, radius: 2)

        var ringCount = 0, structured = 0
        for index in 0..<(width * height) where ring[index] {
            ringCount += 1
            let energy = jxx[index] + jyy[index]
            guard energy > energyThreshold else { continue }
            let difference = jxx[index] - jyy[index]
            let coherence = (difference * difference + 4 * jxy[index] * jxy[index]).squareRoot() / energy
            if coherence > coherenceThreshold { structured += 1 }
        }
        return ringCount > 0 ? Double(structured) / Double(ringCount) : 0
    }


    /// 可分离的方框平均，边缘按实际覆盖的像素数平均
    private static func boxBlur(_ values: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        var horizontal = [Float](repeating: 0, count: values.count)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                let lo = max(0, x - radius), hi = min(width - 1, x + radius)
                for i in lo...hi { sum += values[y * width + i] }
                horizontal[y * width + x] = sum / Float(hi - lo + 1)
            }
        }
        var result = [Float](repeating: 0, count: values.count)
        for x in 0..<width {
            for y in 0..<height {
                var sum: Float = 0
                let lo = max(0, y - radius), hi = min(height - 1, y + radius)
                for j in lo...hi { sum += horizontal[j * width + x] }
                result[y * width + x] = sum / Float(hi - lo + 1)
            }
        }
        return result
    }
}

/// 把人物蒙版按连通块分开，挑出「大半在洞外」的人：他们只是被框压到，补的时候要保住
enum PeopleSplit {
    /// 一个人在洞里的比例低于这个值算被框压到的旁人
    static let insideThreshold = 0.6

    /// 返回只含旁人的蒙版（同尺寸灰度，白色为人）；没有旁人返回 nil
    static func adjacent(_ people: CGImage, hole: CGImage) -> CGImage? {
        let width = people.width, height = people.height
        guard hole.width == width, hole.height == height else { return nil }
        let person = grayPixels(people).map { $0 > 127 }
        let inHole = grayPixels(hole).map { $0 > 127 }
        var label = [Int](repeating: -1, count: width * height)
        var keep = [Bool](repeating: false, count: width * height)
        var found = false
        for start in 0..<(width * height) where person[start] && label[start] < 0 {
            var stack = [start], members: [Int] = []
            label[start] = start
            while let p = stack.popLast() {
                members.append(p)
                let x = p % width, y = p / width
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && ny >= 0 && nx < width && ny < height {
                    let q = ny * width + nx
                    if person[q] && label[q] < 0 { label[q] = start; stack.append(q) }
                }
            }
            let inside = members.reduce(0) { $0 + (inHole[$1] ? 1 : 0) }
            guard Double(inside) / Double(members.count) < insideThreshold else { continue }
            for p in members { keep[p] = true }
            found = true
        }
        guard found, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ), let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        for index in 0..<(width * height) { data[index] = keep[index] ? 255 : 0 }
        return context.makeImage()
    }

}

/// 灰度图的像素（第 0 行在顶部，与 CGContext 内存一致）
func grayPixels(_ image: CGImage) -> [UInt8] {
    let width = image.width, height = image.height
    var values = [UInt8](repeating: 0, count: width * height)
    values.withUnsafeMutableBytes { raw in
        guard let context = CGContext(
            data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return values
}
