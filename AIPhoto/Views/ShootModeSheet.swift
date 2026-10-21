import SwiftUI

/// 打开文件夹时先问：这批照片怎么处理（需求清单第 17 节）。默认选中这个文件夹上次用的方式，回车确认
struct ShootModeSheet: View {
    @Environment(AppModel.self) private var model
    let folder: URL
    @State private var mode: ShootMode

    init(folder: URL, initial: ShootMode) {
        self.folder = folder
        _mode = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("这批照片怎么处理？").font(.title3.bold())
                Text(folder.lastPathComponent).font(.callout).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ForEach(ShootMode.allCases) { option in
                    ModeOption(mode: option, selected: option == mode) { mode = option }
                }
            }
            Text("之后也可以在工具栏上随时切换，已经标过的选用、淘汰不会丢。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { model.pendingOpenFolder = nil }
                    .keyboardShortcut(.cancelAction)
                Button("打开") { model.load(folder, mode: mode) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

private struct ModeOption: View {
    let mode: ShootMode
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .frame(width: 36, height: 36)
                    .background((selected ? Color.accentColor : Color.secondary).opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode.title).font(.headline)
                    Text(mode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .font(.title3)
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
