import Foundation

@MainActor
@Observable
final class BookOrbitMarginaliaModel {
    private(set) var state: BookOrbitLoadState = .loading
    private(set) var items: [BookOrbitProvider.AnnotationHubItem] = []
    private(set) var facets: [BookOrbitProvider.AnnotationHubBookFacet] = []
    private(set) var books: [Int: Book] = [:]
    private(set) var total = 0
    private(set) var withNotes = 0
    private(set) var bookCount = 0
    private(set) var isReloading = false
    private(set) var isLoadingMore = false
    private(set) var loadMoreError: String?
    private(set) var trashed = false
    private(set) var onlyWithNotes = false
    private(set) var bookId: Int?

    var search = ""
    var actionMessage: String?

    @ObservationIgnored private(set) var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var source: (any BookOrbitMarginaliaSource)?
    private var connectionId: UUID?
    private var page = 1
    private var exhausted = false
    private var generation = 0

    private var provider: (any BookOrbitMarginaliaSource)? {
        if let source { return source }
        guard let connectionId else { return nil }
        return BookOrbitAccess.provider(connectionId)
    }

    init(source: (any BookOrbitMarginaliaSource)? = nil) {
        self.source = source
    }

    var canLoadMore: Bool { !isReloading && !exhausted && state == .ready }

    func bind(connectionId: UUID?) {
        self.connectionId = connectionId ?? BookOrbitAccess.connections.first?.id
    }

    func select(bookId newBookId: Int?) {
        guard newBookId != bookId else { return }
        bookId = newBookId
        startReload()
    }

    func select(trashed showTrashed: Bool) {
        guard showTrashed != trashed else { return }
        trashed = showTrashed
        bookId = nil
        startReload()
    }

    func select(onlyWithNotes enabled: Bool) {
        guard enabled != onlyWithNotes else { return }
        onlyWithNotes = enabled
        startReload()
    }

    func reload() async {
        await startReload().value
    }

    @discardableResult
    private func startReload() -> Task<Void, Never> {
        generation += 1
        isReloading = true
        reloadTask?.cancel()
        let requested = generation
        let task = Task { await performReload(requested) }
        reloadTask = task
        return task
    }

    private func performReload(_ requested: Int) async {
        defer { if requested == generation { isReloading = false } }
        guard let provider else {
            state = .unavailable
            return
        }

        page = 1
        exhausted = false
        loadMoreError = nil
        do {
            let response = try await provider.fetchAnnotations(query())
            guard requested == generation, !Task.isCancelled else { return }
            items = response.items
            total = response.total
            withNotes = response.stats.withNotes
            bookCount = response.stats.books
            exhausted = response.items.count >= response.total || response.items.isEmpty
            state = .ready
            await resolveBooks(response.items)
            let fetchedFacets = (try? await provider.fetchAnnotationBooks(trashed: trashed, search: nil)) ?? []
            guard requested == generation, !Task.isCancelled else { return }
            facets = fetchedFacets
        } catch BookOrbitProvider.FeatureError.unavailable {
            guard requested == generation, !Task.isCancelled else { return }
            state = .unavailable
        } catch {
            guard requested == generation, !Task.isCancelled else { return }
            state = .failed(BookOrbitAccess.message(for: error))
        }
    }

    /// `retry` is the explicit button; scrolling never re-requests a page that just failed.
    func loadMore(retry: Bool = false) async {
        guard let provider, canLoadMore, !isLoadingMore, retry || loadMoreError == nil else { return }
        isLoadingMore = true
        loadMoreError = nil
        defer { isLoadingMore = false }

        let requested = generation
        var next = query()
        next.page = page + 1
        do {
            let response = try await provider.fetchAnnotations(next)
            guard requested == generation, !Task.isCancelled else { return }
            page = next.page
            let known = Set(items.map(\.id))
            let fresh = response.items.filter { !known.contains($0.id) }
            items.append(contentsOf: fresh)
            total = response.total
            exhausted = fresh.isEmpty || items.count >= response.total
            await resolveBooks(fresh)
        } catch {
            guard requested == generation, !Task.isCancelled, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            loadMoreError = BookOrbitAccess.message(for: error)
        }
    }

    func trash(_ item: BookOrbitProvider.AnnotationHubItem) async {
        if await mutate(item, { try await $0.trashAnnotations(ids: [item.id]) }) {
            actionMessage = "Moved to the BookOrbit trash"
        }
    }

    func restore(_ item: BookOrbitProvider.AnnotationHubItem) async {
        if await mutate(item, { try await $0.restoreAnnotations(ids: [item.id]) }) {
            actionMessage = "Restored on BookOrbit"
        }
    }

    func purge(_ item: BookOrbitProvider.AnnotationHubItem) async {
        _ = await mutate(item) { try await $0.purgeAnnotation(id: item.id) }
    }

    func export(format: String) async -> URL? {
        guard let provider else { return nil }
        do {
            return try await provider.exportAnnotations(query(), format: format)
        } catch {
            actionMessage = BookOrbitAccess.message(for: error)
            return nil
        }
    }

    private func mutate(
        _ item: BookOrbitProvider.AnnotationHubItem,
        _ action: (any BookOrbitMarginaliaSource) async throws -> Void
    ) async -> Bool {
        guard let provider else { return false }
        do {
            try await action(provider)
            items.removeAll { $0.id == item.id }
            total = max(0, total - 1)
            return true
        } catch {
            actionMessage = BookOrbitAccess.message(for: error)
            return false
        }
    }

    private func query() -> BookOrbitProvider.AnnotationHubQuery {
        BookOrbitProvider.AnnotationHubQuery(
            page: page,
            pageSize: 50,
            bookId: bookId,
            search: search,
            trashed: trashed,
            hasNote: onlyWithNotes
        )
    }

    private func resolveBooks(_ items: [BookOrbitProvider.AnnotationHubItem]) async {
        guard let connectionId else { return }
        let unresolved = items.map(\.bookId).filter { books[$0] == nil }
        guard !unresolved.isEmpty else { return }
        let resolved = await BookOrbitAccess.localBooks(connectionId: connectionId, remoteIds: unresolved)
        books.merge(resolved) { current, _ in current }
    }
}

@MainActor
protocol BookOrbitMarginaliaSource: AnyObject {
    func fetchAnnotations(_ query: BookOrbitProvider.AnnotationHubQuery) async throws -> BookOrbitProvider.AnnotationHubPage
    func fetchAnnotationBooks(trashed: Bool, search: String?) async throws -> [BookOrbitProvider.AnnotationHubBookFacet]
    func trashAnnotations(ids: [Int]) async throws
    func restoreAnnotations(ids: [Int]) async throws
    func purgeAnnotation(id: Int) async throws
    func exportAnnotations(_ query: BookOrbitProvider.AnnotationHubQuery, format: String) async throws -> URL
}

extension BookOrbitProvider: BookOrbitMarginaliaSource {}
