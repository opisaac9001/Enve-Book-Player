#if os(iOS)
import Foundation

@MainActor
protocol BookOrbitBookDropSource: AnyObject {
    func fetchBookDockAccess() async throws -> BookOrbitProvider.BookDockAccess
    func fetchBookDockFiles(_ query: BookOrbitProvider.BookDockQuery) async throws -> BookOrbitProvider.BookDockPage
    func fetchBookDockSummary() async throws -> BookOrbitProvider.BookDockSummary
    func fetchBookDockDestinations() async throws -> [BookOrbitProvider.BookDockDestination]
    func uploadBookDockFile(at fileURL: URL, filename: String) async throws -> BookOrbitProvider.BookDockFile
    func updateBookDockFile(
        id: Int,
        selectedMetadata: [String: Any]?,
        target: (libraryId: Int, folderId: Int)?
    ) async throws -> BookOrbitProvider.BookDockFile
    func setBookDockTarget(ids: [Int], libraryId: Int, folderId: Int) async throws -> BookOrbitProvider.BookDockTargetResult
    func applyFetchedBookDockMetadata(ids: [Int]) async throws -> BookOrbitProvider.BookDockApplyResult
    func refetchBookDockMetadata(id: Int) async throws
    func finalizeBookDockFiles(ids: [Int]) async throws -> BookOrbitProvider.BookDockFinalizeResult
    func discardBookDockFiles(ids: [Int]) async throws
}

extension BookOrbitProvider: BookOrbitBookDropSource {}

@MainActor
@Observable
final class BookOrbitBookDropModel {
    enum State: Equatable {
        case loading
        case ready
        case unavailable
        case denied(String)
        case failed(String)
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, pending, ready, error

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .pending: "Processing"
            case .ready: "Ready"
            case .error: "Failed"
            }
        }
    }

    struct Notice: Equatable {
        let text: String
        let isError: Bool
    }

    private(set) var state: State = .loading
    private(set) var access: BookOrbitProvider.BookDockAccess?
    private(set) var files: [BookOrbitProvider.BookDockFile] = []
    private(set) var total = 0
    private(set) var summary: BookOrbitProvider.BookDockSummary?
    private(set) var destinations: [BookOrbitProvider.BookDockDestination] = []
    private(set) var destinationsError: String?
    private(set) var filter: Filter = .all
    private(set) var refreshError: String?
    private(set) var isReloading = false
    private(set) var isLoadingMore = false
    private(set) var pageError: String?
    private(set) var isUploading = false
    private(set) var busyIds: Set<Int> = []
    private(set) var selection: Set<Int> = []
    private(set) var isSelecting = false

    var search = ""
    var notice: Notice?
    var finalizeResult: BookOrbitProvider.BookDockFinalizeResult?

    @ObservationIgnored private let source: (any BookOrbitBookDropSource)?
    @ObservationIgnored private(set) var reloadTask: Task<Void, Never>?
    private var generation = 0
    private var appliedSearch = ""
    private var page = 1
    private var exhausted = false

    static let pageSize = 50
    static let deniedMessage =
        "Your BookOrbit account doesn't have Library Dock access. Ask the server's administrator to grant it."

    var canFinalize: Bool { access?.canFinalize == true }
    var hasMore: Bool { state == .ready && !isReloading && !exhausted && files.count < total }
    var selectedFiles: [BookOrbitProvider.BookDockFile] { files.filter { selection.contains($0.id) } }

    init(source: (any BookOrbitBookDropSource)?) {
        self.source = source
    }

    func isBusy(_ ids: [Int]) -> Bool {
        ids.contains { busyIds.contains($0) }
    }

    func load() async {
        guard let source else {
            state = .unavailable
            return
        }
        do {
            let access = try await source.fetchBookDockAccess()
            self.access = access
            guard access.canUse else {
                state = .denied(Self.deniedMessage)
                return
            }
        } catch {
            guard !Self.isCancellation(error) else { return }
            let message = BookOrbitAccess.message(for: error)
            if files.isEmpty {
                state = .failed(message)
            } else {
                refreshError = message
            }
            return
        }
        await reload()
        await loadDestinations()
    }

    func reload() async {
        startReload()
        await reloadTask?.value
    }

    func select(_ newFilter: Filter) {
        guard newFilter != filter else { return }
        filter = newFilter
        files = []
        total = 0
        selection = []
        startReload()
    }

    func searchChanged() {
        guard access?.canUse == true, search != appliedSearch else { return }
        selection = []
        startReload()
    }

    /// `retry` is the explicit button; scrolling never re-requests a page that just failed.
    func loadMore(retry: Bool = false) async {
        guard let source, hasMore, !isLoadingMore, retry || pageError == nil else { return }
        isLoadingMore = true
        pageError = nil
        defer { isLoadingMore = false }

        let requested = generation
        do {
            let result = try await source.fetchBookDockFiles(query(page: page + 1))
            guard requested == generation, !Task.isCancelled else { return }
            page += 1
            let known = Set(files.map(\.id))
            let fresh = result.items.filter { !known.contains($0.id) }
            files.append(contentsOf: fresh)
            total = result.total
            exhausted = fresh.isEmpty
        } catch {
            guard requested == generation, !Self.isCancellation(error) else { return }
            pageError = BookOrbitAccess.message(for: error)
        }
    }

    func toggleSelecting() {
        isSelecting.toggle()
        selection = []
    }

    func toggleSelected(_ id: Int) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    func loadDestinations() async {
        guard let source else { return }
        do {
            destinations = try await source.fetchBookDockDestinations()
            destinationsError = nil
        } catch {
            guard !Self.isCancellation(error) else { return }
            destinationsError = BookOrbitAccess.message(for: error)
        }
    }

    func upload(fileURL: URL) async {
        guard let source, !isUploading else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            let file = try await source.uploadBookDockFile(at: fileURL, filename: fileURL.lastPathComponent)
            notice = Notice(text: "\(file.fileName) is in the Book Drop. BookOrbit is reading it now.", isError: false)
            await reload()
        } catch {
            guard !Self.isCancellation(error) else { return }
            notice = Notice(
                text: "\(fileURL.lastPathComponent) wasn't added. \(BookOrbitAccess.message(for: error))",
                isError: true
            )
        }
    }

    @discardableResult
    func save(
        _ file: BookOrbitProvider.BookDockFile,
        metadata: BookOrbitProvider.BookDockMetadata,
        target: (libraryId: Int, folderId: Int)?
    ) async -> BookOrbitProvider.BookDockFile? {
        let changes = metadata.changes(from: file.metadata)
        let retarget = target.flatMap { $0.libraryId == file.targetLibraryId && $0.folderId == file.targetFolderId ? nil : $0 }
        guard !changes.isEmpty || retarget != nil else { return file }

        let existing = file.selectedMetadataJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        // Manual filing uses selectedMetadata as the complete record, without merging embedded fields.
        let selected = changes.isEmpty ? nil : file.metadata.changes(from: .init())
            .merging(existing ?? [:]) { _, selected in selected }
            .merging(changes) { _, edited in edited }
        return await mutate([file.id]) { source in
            let saved = try await source.updateBookDockFile(id: file.id, selectedMetadata: selected, target: retarget)
            self.replace(saved)
            self.notice = Notice(text: "Saved \(saved.fileName) on BookOrbit.", isError: false)
            return saved
        }
    }

    func applyFetched(ids: [Int]) async {
        await mutate(ids) { source in
            let result = try await source.applyFetchedBookDockMetadata(ids: ids)
            self.notice = Notice(text: Self.describe(result), isError: result.applied == 0)
            await self.reload()
        }
    }

    func refetch(id: Int) async {
        await mutate([id]) { source in
            try await source.refetchBookDockMetadata(id: id)
            self.notice = Notice(text: "BookOrbit is looking up metadata again.", isError: false)
            await self.reload()
        }
    }

    func setTarget(ids: [Int], libraryId: Int, folderId: Int) async {
        await mutate(ids) { source in
            let result = try await source.setBookDockTarget(ids: ids, libraryId: libraryId, folderId: folderId)
            let text = result.failed == 0
                ? "Destination set for \(Self.count(result.updated))."
                : "Destination set for \(Self.count(result.updated)); \(result.failed) could not be changed."
            self.notice = Notice(text: text, isError: result.failed > 0)
            await self.reload()
        }
    }

    func finalize(ids: [Int]) async {
        guard canFinalize, !ids.isEmpty else { return }
        await mutate(ids) { source in
            let result = try await source.finalizeBookDockFiles(ids: ids)
            self.finalizeResult = result
            self.selection.subtract(result.results.filter(\.success).map(\.fileId))
            await self.reload()
        }
    }

    func discard(ids: [Int]) async {
        await mutate(ids) { source in
            try await source.discardBookDockFiles(ids: ids)
            self.files.removeAll { ids.contains($0.id) }
            self.total = max(0, self.total - ids.count)
            self.selection.subtract(ids)
            self.notice = Notice(text: "Discarded \(Self.count(ids.count)) from the Book Drop.", isError: false)
            await self.reload()
        }
    }

    @discardableResult
    private func mutate<Value>(
        _ ids: [Int],
        _ action: (any BookOrbitBookDropSource) async throws -> Value
    ) async -> Value? {
        guard let source, !ids.isEmpty, !isBusy(ids) else { return nil }
        busyIds.formUnion(ids)
        defer { busyIds.subtract(ids) }
        do {
            return try await action(source)
        } catch {
            guard !Self.isCancellation(error) else { return nil }
            notice = Notice(text: BookOrbitAccess.message(for: error), isError: true)
            return nil
        }
    }

    private func replace(_ file: BookOrbitProvider.BookDockFile) {
        guard let index = files.firstIndex(where: { $0.id == file.id }) else { return }
        files[index] = file
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
        guard let source else { return }
        pageError = nil
        refreshError = nil
        isReloading = true
        defer { if requested == generation { isReloading = false } }
        do {
            let result = try await source.fetchBookDockFiles(query(page: 1))
            guard requested == generation, !Task.isCancelled else { return }
            page = 1
            files = result.items
            total = result.total
            exhausted = result.items.isEmpty
            selection.formIntersection(result.items.map(\.id))
            state = .ready
        } catch BookOrbitProvider.FeatureError.unavailable {
            guard requested == generation else { return }
            state = .unavailable
            return
        } catch BookOrbitProvider.BookDockError.accessDenied {
            guard requested == generation else { return }
            files = []
            total = 0
            state = .denied(Self.deniedMessage)
            return
        } catch {
            guard requested == generation, !Self.isCancellation(error) else { return }
            let message = BookOrbitAccess.message(for: error)
            if files.isEmpty {
                state = .failed(message)
            } else {
                refreshError = message
            }
            return
        }
        if let summary = try? await source.fetchBookDockSummary(), requested == generation {
            self.summary = summary
        }
    }

    private func query(page: Int) -> BookOrbitProvider.BookDockQuery {
        BookOrbitProvider.BookDockQuery(
            page: page,
            limit: Self.pageSize,
            status: filter == .all ? nil : filter.rawValue,
            search: search
        )
    }

    static func describe(_ result: BookOrbitProvider.BookDockApplyResult) -> String {
        var parts = ["Fetched metadata applied to \(count(result.applied))."]
        if result.skipped > 0 { parts.append("\(count(result.skipped)) had no fetched metadata.") }
        if result.skippedEdited > 0 { parts.append("\(count(result.skippedEdited)) kept edits made by hand.") }
        return parts.joined(separator: " ")
    }

    private static func count(_ n: Int) -> String {
        n == 1 ? "1 file" : "\(n) files"
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

enum BookOrbitBookDropFormat {
    static func status(_ file: BookOrbitProvider.BookDockFile) -> String {
        switch file.status {
        case "ready":
            file.holdReason.map { "Needs review: \(hold($0, detail: file.holdDetail))" } ?? "Ready to file"
        case "error":
            file.errorMessage.map { "Failed: \($0)" } ?? "Failed"
        case "pending": "Waiting to be read"
        case "extracting": "Reading the file"
        case "fetching": "Looking up metadata"
        default: file.status.capitalized
        }
    }

    /// Unknown reasons read as a plain review hold, as the server contract asks.
    static func hold(_ reason: String, detail: BookOrbitProvider.BookDockFile.HoldDetail?) -> String {
        let library = detail?.libraryName.map { " in \($0)" } ?? ""
        switch reason {
        case "low_confidence": return "the metadata match is weak"
        case "no_destination": return "no library chosen"
        case "no_folder": return "the library folder was removed"
        case "not_allowed_in_library": return "this format isn't accepted\(library)"
        case "duplicate": return "this book is already\(library.isEmpty ? " in the library" : library)"
        case "destination_conflict": return "a file already sits at the destination"
        case "unsupported_layout": return "the library can't hold this multi-file book"
        case "waiting_for_manager": return "a Library Dock manager must file it"
        default: return "waiting for review"
        }
    }

    static func outcome(_ result: BookOrbitProvider.BookDockFinalizeResult.FileResult) -> String {
        if result.success { return result.newName.map { "Filed as \($0)" } ?? "Filed" }
        if result.isDuplicate == true { return result.message ?? "Already in the library" }
        return result.message ?? "Not filed"
    }
}
#endif
