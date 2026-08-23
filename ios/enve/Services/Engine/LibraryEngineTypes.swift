import Foundation

enum LibraryStatusFilter: String, CaseIterable {
    case all, listening, reading, finished, downloaded

    var title: String {
        switch self {
        case .all: "All"
        case .listening: "Listening"
        case .reading: "Reading"
        case .finished: "Finished"
        case .downloaded: "Downloaded"
        }
    }
}

enum LibrarySort: String, CaseIterable, Codable {
    case recent, recentlyRead, title, author, authorSurname, narrator, narratorSurname, series, progress, duration, year, goodreadsRating

    var title: String {
        switch self {
        case .recent: "Recently Added"
        case .recentlyRead: "Recently Read"
        case .title: "Title"
        case .author: "Author given"
        case .authorSurname: "Author surname"
        case .narrator: "Narrator given"
        case .narratorSurname: "Narrator surname"
        case .series: "Series"
        case .progress: "Progress"
        case .duration: "Duration"
        case .year: "Published year"
        case .goodreadsRating: "Rating"
        }
    }
}

enum LibrarySortDirection: String, CaseIterable, Codable {
    case ascending, descending

    var title: String {
        switch self {
        case .ascending: "Ascending"
        case .descending: "Descending"
        }
    }

    var glyph: String {
        switch self {
        case .ascending: "arrow.up"
        case .descending: "arrow.down"
        }
    }
}

struct LibrarySortDescriptor: Hashable, Codable {
    var field: LibrarySort
    var direction: LibrarySortDirection

    var title: String {
        field.title
    }

    var summary: String {
        "\(field.title) \(direction == .ascending ? "asc" : "desc")"
    }
}

enum DetailSeriesOrder {
    static func sorted(_ books: [Book]) -> [Book] {
        books.sorted { lhs, rhs in
            let l = sequence(of: lhs)
            let r = sequence(of: rhs)
            if l != r { return l < r }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private static func sequence(of book: Book) -> Double {
        book.seriesSequence.flatMap(Double.init)
            ?? book.seriesNumber.map(Double.init)
            ?? .greatestFiniteMagnitude
    }
}

enum LibraryBookActions {
    static func isDownloaded(_ book: Book) -> Bool {
        EnveEngine.shared.downloads.isLibraryDownloaded(book)
    }

    static func hasPermanentEbookDownload(_ book: Book) -> Bool {
        EnveEngine.shared.downloads.hasPermanentEbookDownload(book)
    }

    static func removeDownload(_ book: Book) {
        Task { await EnveEngine.shared.downloads.removeLibraryDownload(for: book) }
    }

    static func progressFraction(_ book: Book) -> Double {
        if book.mediaType == .ebook {
            return book.canonicalEbookProgress
        }
        guard let duration = book.duration, duration > 0 else { return 0 }
        return min(max(book.currentTime / duration, 0), 1)
    }
}
