import Foundation

enum RemoteCatalogSort: Equatable, Sendable {
    case title
    case recentlyAdded
}

struct RemoteCatalogRequest: Equatable, Sendable {
    var search: String?
    var mediaType: AppMediaType?
    var sort: RemoteCatalogSort
    var genres: Set<String> = []
    var languages: Set<String> = []

    func matchesAdvancedFilters(_ book: Book) -> Bool {
        if !genres.isEmpty,
            Set(genres.map(Self.folded)).isDisjoint(with: (book.genres ?? []).map(Self.folded)) {
            return false
        }
        if !languages.isEmpty {
            guard let language = book.language,
                Set(languages.map(Self.folded)).contains(Self.folded(language)) else { return false }
        }
        return true
    }

    func onDeviceBooks(
        from candidates: [Book],
        providerId: UUID?,
        libraryId: String?,
        isOnDevice: (Book) -> Bool
    ) -> [Book] {
        let terms = search.map(Self.folded)?.split(separator: " ").map(String.init) ?? []
        var seen = Set<String>()
        return candidates
            .filter { book in
                (providerId == nil || book.providerId == providerId)
                    && (libraryId == nil || book.libraryId == libraryId)
                    && (mediaType == nil || book.mediaType == mediaType)
                    && Self.matches(book, terms: terms)
                    && matchesAdvancedFilters(book)
                    && isOnDevice(book)
                    && seen.insert(book.uniqueId).inserted
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func matches(_ book: Book, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = folded(
            ([book.title, book.author, book.narrator, book.series].compactMap { $0 } + (book.authors ?? []))
                .joined(separator: " ")
        )
        return terms.allSatisfy(haystack.contains)
    }

    private static func folded(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct RemoteCatalogPage {
    let books: [Book]
    let nextCursor: String?
}

// Summary pages apply filters before pagination and never authorize catalog deletion.
protocol RemoteCatalogBrowsingProvider: LibraryProvider {
    func fetchRemoteCatalogPage(
        libraryId: String,
        request: RemoteCatalogRequest,
        cursor: String?,
        limit: Int
    ) async throws -> RemoteCatalogPage

    func fetchRemoteCatalogFilterOptions(
        libraryId: String, mediaType: AppMediaType?, search: String
    ) async throws -> RemoteCatalogFilterOptions
}

struct RemoteCatalogFilterOptions: Sendable {
    var genres: [String] = []
    var languages: [String] = []
    var hasMore = false
}

extension RemoteCatalogBrowsingProvider {
    func fetchRemoteCatalogFilterOptions(
        libraryId: String, mediaType: AppMediaType?, search: String
    ) async throws -> RemoteCatalogFilterOptions {
        throw ProviderError.notImplemented
    }
}

enum RemoteCatalogConnectivity {
    static func isUnavailable(_ error: any Error) -> Bool {
        if case ProviderError.networkError = error { return true }
        guard let code = (error as? URLError)?.code else { return false }
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            return true
        default:
            return false
        }
    }
}
