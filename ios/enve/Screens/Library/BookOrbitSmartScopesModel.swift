#if os(iOS)
import Foundation

@MainActor
protocol BookOrbitSmartScopeSource: AnyObject {
    func fetchSmartScopes() async throws -> [BookOrbitProvider.SmartScope]
    func fetchSmartScopeBooks(
        scopeId: Int,
        query: BookOrbitProvider.SmartScopeQuery
    ) async throws -> BookOrbitProvider.CollectionPage
}

extension BookOrbitProvider: BookOrbitSmartScopeSource {}

@MainActor
@Observable
final class BookOrbitSmartScopesModel {
    enum BooksState: Equatable {
        case idle
        case loading
        case ready
        case failed(String)
    }

    private(set) var scopesState: BookOrbitLoadState = .loading
    private(set) var scopes: [BookOrbitProvider.SmartScope] = []
    private(set) var scopesRefreshError: String?
    private(set) var selectedScopeId: Int?

    private(set) var booksState: BooksState = .idle
    private(set) var books: [Book] = []
    private(set) var total = 0
    private(set) var booksRefreshError: String?
    private(set) var isReloading = false
    private(set) var isLoadingMore = false
    private(set) var pageError: String?

    var search = ""

    @ObservationIgnored private let source: (any BookOrbitSmartScopeSource)?
    @ObservationIgnored private let localBooks: @MainActor ([Int]) async -> [Int: Book]
    @ObservationIgnored private(set) var reloadTask: Task<Void, Never>?
    private var generation = 0
    private var appliedSearch = ""
    private var page = 0
    private var exhausted = false

    static let pageSize = 50

    var selectedScope: BookOrbitProvider.SmartScope? {
        scopes.first { $0.id == selectedScopeId }
    }

    var hasMore: Bool { booksState == .ready && !isReloading && !exhausted && books.count < total }

    init(
        source: (any BookOrbitSmartScopeSource)?,
        localBooks: @escaping @MainActor ([Int]) async -> [Int: Book] = { _ in [:] }
    ) {
        self.source = source
        self.localBooks = localBooks
    }

    func loadScopes() async {
        guard let source else {
            scopesState = .unavailable
            return
        }
        do {
            let fetched = try await source.fetchSmartScopes()
            guard !Task.isCancelled else { return }
            scopes = fetched
            scopesRefreshError = nil
            scopesState = .ready
            if let selectedScopeId, !fetched.contains(where: { $0.id == selectedScopeId }) {
                clearSelection()
            }
            if selectedScopeId == nil, let first = fetched.first {
                select(scopeId: first.id)
            }
        } catch BookOrbitProvider.FeatureError.unavailable {
            scopesState = .unavailable
        } catch {
            guard !Self.isCancellation(error) else { return }
            let message = BookOrbitAccess.message(for: error)
            if scopes.isEmpty {
                scopesState = .failed(message)
            } else {
                scopesRefreshError = message
            }
        }
    }

    func select(scopeId: Int) {
        guard scopeId != selectedScopeId else { return }
        selectedScopeId = scopeId
        search = ""
        books = []
        total = 0
        startReload()
    }

    func searchChanged() {
        guard selectedScopeId != nil, search != appliedSearch else { return }
        startReload()
    }

    func reloadBooks() async {
        startReload()
        await reloadTask?.value
    }

    /// `retry` is the explicit button; scrolling never re-requests a page that just failed.
    func loadMore(retry: Bool = false) async {
        guard let source, let scopeId = selectedScopeId, hasMore, !isLoadingMore, retry || pageError == nil else { return }
        isLoadingMore = true
        pageError = nil
        defer { isLoadingMore = false }

        let requested = generation
        do {
            let result = try await source.fetchSmartScopeBooks(scopeId: scopeId, query: query(page: page + 1))
            let resolved = await resolve(result.books)
            guard requested == generation, !Task.isCancelled else { return }
            page += 1
            let known = Set(books.map(\.id))
            let fresh = resolved.filter { !known.contains($0.id) }
            books.append(contentsOf: fresh)
            total = result.total
            exhausted = fresh.isEmpty
        } catch {
            guard requested == generation, !Self.isCancellation(error) else { return }
            pageError = BookOrbitAccess.message(for: error)
        }
    }

    private func clearSelection() {
        reloadTask?.cancel()
        generation += 1
        selectedScopeId = nil
        isReloading = false
        books = []
        total = 0
        booksState = .idle
        booksRefreshError = nil
        pageError = nil
    }

    private func startReload() {
        isReloading = true
        reloadTask?.cancel()
        generation += 1
        appliedSearch = search
        let requested = generation
        reloadTask = Task { await performReload(requested) }
    }

    private func performReload(_ requested: Int) async {
        defer { if requested == generation { isReloading = false } }
        guard let source, let scopeId = selectedScopeId else { return }
        pageError = nil
        booksRefreshError = nil
        if books.isEmpty { booksState = .loading }
        do {
            let result = try await source.fetchSmartScopeBooks(scopeId: scopeId, query: query(page: 0))
            let resolved = await resolve(result.books)
            guard requested == generation, !Task.isCancelled else { return }
            page = 0
            books = resolved
            total = result.total
            exhausted = resolved.isEmpty
            booksState = .ready
        } catch {
            guard requested == generation, !Self.isCancellation(error) else { return }
            let message = BookOrbitAccess.message(for: error)
            if books.isEmpty {
                booksState = .failed(message)
            } else {
                booksRefreshError = message
            }
        }
    }

    private func query(page: Int) -> BookOrbitProvider.SmartScopeQuery {
        BookOrbitProvider.SmartScopeQuery(page: page, size: Self.pageSize, search: search)
    }

    /// A stored row carries progress, downloads, and resolved metadata the server card lacks.
    private func resolve(_ cards: [Book]) async -> [Book] {
        let stored = await localBooks(cards.compactMap { Int($0.id) })
        return cards.map { card in Int(card.id).flatMap { stored[$0] } ?? card }
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}
#endif
