import Foundation

enum LibrarySeriesFilter: String, CaseIterable, Codable {
    case all
    case inSeries
    case standalone

    var title: String {
        switch self {
        case .all: "Any"
        case .inSeries: "In a series"
        case .standalone: "Standalone"
        }
    }
}

struct LibraryAdvancedFilters: Codable, Equatable {
    var genres: Set<String> = []
    var languages: Set<String> = []
    var minimumRating: Double?
    var series: LibrarySeriesFilter = .all

    var isActive: Bool {
        !genres.isEmpty || !languages.isEmpty || minimumRating != nil || series != .all
    }

    static let empty = LibraryAdvancedFilters()
}

struct LibraryAdvancedFilterOptions {
    var genres: [String] = []
    var languages: [String] = []
}

enum LibraryAdvancedFilterPolicy {
    static func matches(_ book: Book, filters: LibraryAdvancedFilters) -> Bool {
        if !filters.genres.isEmpty {
            let selected = Set(filters.genres.map(normalized))
            let bookGenres = Set((book.genres ?? []).map(normalized))
            guard !selected.isDisjoint(with: bookGenres) else { return false }
        }
        if !filters.languages.isEmpty {
            let selected = Set(filters.languages.map(normalized))
            guard let language = book.language.map(normalized), selected.contains(language) else { return false }
        }
        if let minimumRating = filters.minimumRating,
            max(book.personalRating ?? 0, book.goodreadsRating ?? 0) < minimumRating
        {
            return false
        }
        let hasSeries = !(book.series?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        switch filters.series {
        case .all: break
        case .inSeries where !hasSeries: return false
        case .standalone where hasSeries: return false
        default: break
        }
        return true
    }

    static func options(from books: [Book]) -> LibraryAdvancedFilterOptions {
        LibraryAdvancedFilterOptions(
            genres: uniqueSorted(books.flatMap { $0.genres ?? [] }),
            languages: uniqueSorted(books.compactMap(\.language))
        )
    }

    static func uniqueSorted(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return
            values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert(normalized($0)).inserted }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
