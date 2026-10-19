import SwiftUI

struct Filmstrip: View {
    @Environment(AppModel.self) private var model
    let photos: [Photo]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(photos) { photo in
                        FilmstripCell(photo: photo, selected: photo.id == model.selectedPhotoID)
                            .id(photo.id)
                            .onTapGesture { model.selectPhoto(photo.id) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: model.selectedPhotoID) { _, id in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .background(.background.secondary)
    }
}

struct FilmstripCell: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    let selected: Bool

    var body: some View {
        Thumbnail(url: photo.displayURL, size: CGSize(width: 128, height: 96))
            .opacity(photo.decision == .reject ? 0.4 : 1)
            .overlay(alignment: .topLeading) {
                Group {
                    switch photo.decision {
                    case .pick: Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, .green)
                    case .reject: Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .red)
                    case .none: EmptyView()
                    }
                }
                .font(.title3)
                .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if let ai = photo.ai {
                    Text("\(ai.score)")
                        .badgeStyle(ai.pick ? .purple : .gray)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    if model.isCleaning(photo.id) {
                        Text("修复中").badgeStyle(.blue)
                    } else if photo.retouchLog?.needsReview == true {
                        Text("需检查").badgeStyle(.pink)
                    }
                    ForEach(photo.flags.sorted { $0.rawValue < $1.rawValue }, id: \.self) { flag in
                        Text(flag.label).badgeStyle(.orange)
                    }
                }
                .padding(4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .stroke(selected ? Color.accentColor : .clear, lineWidth: 3)
            }
    }
}
