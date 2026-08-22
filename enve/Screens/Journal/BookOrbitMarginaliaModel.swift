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
    private(set) var isLoadingMore = false
    private(set) var trashed = false
    private(set) var bookId: Int?

    var search = ""
    var actionMessage: String?

    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    private var connectionId: UUID?
    private var page = 1
    private var exhausted = false

    private var provider: BookOrbitProvider? {
        connectionId.flatMap { BookOrbitAccess.provider($0) }
    }

    var canLoadMore: Bool { !exhausted && state == .ready }

    func bind(connectionId: UUID?) {
        self.connectionId = connectionId ?? BookOrbitAccess.connections.first?.id
    }

    func select(bookId newBookId: Int?) {
        guard newBookId != bookId else { return }
        bookId = newBookId
        reloadTask?.cancel()
        reloadTask = Task { await performReload() }
    }

    func select(trashed showTrashed: Bool) {
        guard showTrashed != trashed else { return }
        trashed = showTrashed
        bookId = nil
        reloadTask?.cancel()
        reloadTask = Task { await performReload() }
    }

    func reload() async {
        reloadTask?.cancel()
        let task = Task { await performReload() }
        reloadTask = task
        await task.value
    }

    private func performReload() async {
        guard let provider else {
            state = .unavailable
            return
        }

        page = 1
        exhausted = false
        do {
            let response = try await provider.fetchAnnotations(query())
            guard !Task.isCancelled else { return }
            items = response.items
            total = response.total
            withNotes = response.stats.withNotes
            bookCount = response.stats.books
            exhausted = response.items.count >= response.total || response.items.isEmpty
            state = .ready
            await resolveBooks(response.items)
            facets = (try? await provider.fetchAnnotationBooks(trashed: trashed, search: nil)) ?? []
        } catch BookOrbitProvider.FeatureError.unavailable {
            state = .unavailable
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(BookOrbitAccess.message(for: error))
        }
    }

    func loadMore() async {
        guard let provider, canLoadMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        page += 1
        guard let response = try? await provider.fetchAnnotations(query()) else {
            page -= 1
            exhausted = true
            return
        }
        guard !Task.isCancelled else { return }
        let known = Set(items.map(\.id))
        let fresh = response.items.filter { !known.contains($0.id) }
        items.append(contentsOf: fresh)
        total = response.total
        exhausted = fresh.isEmpty || items.count >= response.total
        await resolveBooks(fresh)
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
        _ action: (BookOrbitProvider) async throws -> Void
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
            trashed: trashed
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
