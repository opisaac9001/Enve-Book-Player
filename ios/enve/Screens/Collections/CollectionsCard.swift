import SwiftUI
import UIKit

func collectionsTint(_ name: String) -> Color {
    switch name.lowercased().replacingOccurrences(of: "system", with: "") {
    case "blue": .blue
    case "green": .green
    case "red": .red
    case "orange": .orange
    case "purple": .purple
    case "yellow": .yellow
    case "gray": .gray
    case "teal": .teal
    case "indigo": .indigo
    case "pink": .pink
    default: Hearth.accent
    }
}

struct CollectionsCard: View {
    let name: String
    let count: Int
    let iconName: String
    let colorName: String
    var customCoverPath: String?
    var previewBook: Book?
    var representativeThumb: String?
    var badge: String?

    @Environment(\.hearth) private var hearth

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CollectionsCoverView(
                iconName: iconName,
                colorName: colorName,
                customCoverPath: customCoverPath,
                previewBook: previewBook,
                representativeThumb: representativeThumb
            )

            LinearGradient(
                colors: [.black.opacity(0.78), .black.opacity(0.28), .clear],
                startPoint: .bottom,
                endPoint: .top
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.hearthDisplay(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(count == 1 ? "1 book" : "\(count) books")
                        .font(.hearthUI(11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    if let badge {
                        Text("·")
                            .foregroundStyle(.white.opacity(0.6))
                        Text(badge)
                            .font(.hearthUI(11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .padding(12)
        }
        .frame(height: 130)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Hearth.radiusCard, style: .continuous)
                .strokeBorder(hearth.hairline, lineWidth: 1)
        }
        .shadow(color: .black.opacity(hearth.isInk ? 0.35 : 0.12), radius: 12, y: 6)
    }
}

struct CollectionsCoverView: View {
    let iconName: String
    let colorName: String
    var customCoverPath: String?
    var previewBook: Book?
    var representativeThumb: String?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                let tint = collectionsTint(colorName)
                LinearGradient(
                    colors: [tint.opacity(0.42), tint.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if let path = customCoverPath, !path.isEmpty, let image = UIImage(contentsOfFile: path) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else if let book = previewBook, book.coverURL != nil {
                    CachedAsyncCoverImage(
                        url: book.coverURL,
                        fallbackColor: colorName,
                        headers: CachedAsyncCoverImage.authHeaders(for: book),
                        book: book
                    )
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                } else if let thumb = representativeThumb, let url = URL(string: thumb) {
                    CachedAsyncCoverImage(url: url, fallbackColor: colorName, headers: [:], book: nil)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Image(systemName: iconName)
                        .font(.hearthUI(30, weight: .medium))
                        .foregroundStyle(tint)
                }
            }
        }
    }
}
