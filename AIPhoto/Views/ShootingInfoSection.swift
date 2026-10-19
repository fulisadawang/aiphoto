import SwiftUI

/// 直方图与拍摄参数：判断曝光还能不能救、快门是否慢到会拖影
struct ShootingInfoSection: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    @State private var info: ShootingInfo?

    var body: some View {
        Section("直方图与拍摄参数") {
            if let histogram = model.histogram {
                HistogramView(histogram: histogram)
                    .frame(height: 70)
            }
            if let info {
                HStack(spacing: 12) {
                    ForEach([info.shutter, info.aperture, info.iso, info.focalLength].compactMap { $0 }, id: \.self) {
                        Text($0).monospacedDigit()
                    }
                }
                .font(.callout.weight(.medium))
                if let lens = info.lens { LabeledContent("镜头", value: lens) }
                if let camera = info.camera { LabeledContent("相机", value: camera) }
            }
        }
        .task(id: photo.id) {
            let url = photo.renderedURL ?? photo.displayURL
            info = await Task.detached { ViewingAids.shootingInfo(at: url) }.value
        }
    }
}

struct HistogramView: View {
    let histogram: Histogram

    var body: some View {
        Canvas { context, size in
            for (values, color) in [(histogram.red, Color.red), (histogram.green, Color.green), (histogram.blue, Color.blue)] {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (index, value) in values.enumerated() {
                    path.addLine(to: CGPoint(
                        x: CGFloat(index) / CGFloat(values.count - 1) * size.width,
                        y: size.height * (1 - CGFloat(value))
                    ))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                // 三个通道用"滤色"叠加，重叠处变亮，和 Lightroom 的直方图观感一致
                context.blendMode = .screen
                context.fill(path, with: .color(color.opacity(0.55)))
            }
        }
        .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
    }
}
