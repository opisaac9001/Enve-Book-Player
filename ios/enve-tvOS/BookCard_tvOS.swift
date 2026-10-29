import SwiftUI

struct BookRoute_tvOS: Identifiable, Hashable {
    let book: Book
    var id: String { book.stableId }

    static func == (lhs: BookRoute_tvOS, rhs: BookRoute_tvOS) -> Bool {
        lhs.book.stableId == rhs.book.stableId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(book.stableId)
    }
}

struct BookCard_tvOS: View {
    let book: Book
    let width: CGFloat
    let height: CGFloat
    let onSelect: () -> Void

    init(book: Book, width: CGFloat = 240, height: CGFloat = 360, onSelect: @escaping () -> Void) {
        self.book = book
        self.width = width
        self.height = height
        self.onSelect = onSelect
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                coverImage
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let author = book.author, !author.isEmpty {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(width: width, alignment: .leading)
            }
        }
        .buttonStyle(.card)
    }

    private var coverImage: some View {
        CachedAsyncCoverImage(
            url: book.coverURL,
            fallbackColor: "Blue",
            headers: CachedAsyncCoverImage.authHeaders(for: book),
            book: book
        )
    }
}
