import SwiftUI

struct DiscoverScreenHeader: View {
    let overline: String
    let title: String
    var line: String?

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Overline(overline)
            Text(title)
                .font(.hearthScreenTitle)
                .foregroundStyle(hearth.text)
            if let line {
                Text(line)
                    .font(.hearthBody)
                    .foregroundStyle(hearth.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
    }
}

struct DiscoverArtTile: View {
    let book: DiscoverBook
    var width: CGFloat
    var isInLibrary = false

    @Environment(\.hearth) private var hearth

    var body: some View {
        CachedAsyncCoverImage(url: book.highResArtworkURL, fallbackColor: "Blue")
            .aspectRatio(1, contentMode: .fill)
            .frame(width: width, height: width)
            .clipShape(RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                    .strokeBorder(hearth.hairline, lineWidth: 1)
            }
            .overlay(alignment: .topTrailing) {
                if isInLibrary {
                    Image(systemName: "checkmark")
                        .font(.hearthUI(9, weight: .bold))
                        .foregroundStyle(hearth.onEmber)
                        .padding(5)
                        .background(Circle().fill(hearth.ember))
                        .padding(6)
                        .accessibilityLabel("In your library")
                }
            }
            .shadow(color: .black.opacity(hearth.isInk ? 0.45 : 0.18), radius: 14, y: 8)
    }
}

struct DiscoverCard: View {
    let book: DiscoverBook
    let isInLibrary: Bool
    var width: CGFloat = 132

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .center, spacing: 8) {
            DiscoverArtTile(book: book, width: width, isInLibrary: isInLibrary)
            VStack(alignment: .center, spacing: 2) {
                Text(LibraryDisplayFormatter.displayTitle(book.title))
                    .font(.hearthDisplay(14, weight: .semibold))
                    .foregroundStyle(hearth.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text(book.author)
                    .font(.hearthUI(12))
                    .foregroundStyle(hearth.textSecondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                if let duration = book.formattedDuration {
                    Text(duration)
                        .font(.hearthUI(11))
                        .foregroundStyle(hearth.textTertiary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(width: width, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title) by \(book.author)\(isInLibrary ? ", in your library" : "")")
    }
}

struct DiscoverPlaceholderShelf: View {
    let title: String

    @Environment(\.hearth) private var hearth

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ShelfHeader(title: title)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<5, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: Hearth.radiusCover, style: .continuous)
                                .fill(hearth.bgElevated)
                                .frame(width: 132, height: 132)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(hearth.bgElevated)
                                .frame(width: 100, height: 12)
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(hearth.bgElevated)
                                .frame(width: 64, height: 10)
                        }
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            .scrollDisabled(true)
        }
    }
}

enum DiscoverLibraryLookup {

    static func keys(from pairs: [(title: String, author: String)]) -> Set<String> {
        var collected = Set<String>()
        for (rawTitle, rawAuthor) in pairs {
            let title = rawTitle.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let author = rawAuthor.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if title.count > 3 {
                collected.insert("\(title)|\(author)")
            }
        }
        return collected
    }

    static func contains(_ book: DiscoverBook, in keys: Set<String>) -> Bool {
        let title = book.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let author = book.author.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count > 3 else { return false }
        return keys.contains("\(title)|\(author)")
    }
}
