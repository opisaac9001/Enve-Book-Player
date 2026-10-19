import Foundation
import ImageIO

final class ServerPageStreamingService: @unchecked Sendable {
    static let shared = ServerPageStreamingService()

    private static let windowRadius = 3
    private static let prefetchBatchSize = 4

    private let cache: ReadingCacheStore
    private var sources: [String: StreamSource] = [:]
    private var streamIDsByBook: [String: String] = [:]
    private var prefetches: [String: Prefetch] = [:]
    private var pageTasks: [String: PageTask] = [:]
    private var nextTaskID = 0
    private var windowRevisions: [String: Int] = [:]

    private let cacheRoot: URL

    init(
        cachesDirectory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
        cache: ReadingCacheStore? = nil
    ) {
        cacheRoot = cachesDirectory.appendingPathComponent("StreamedPages", isDirectory: true)
        self.cache = cache ?? ReadingCacheStore(cachesDirectory: cachesDirectory)
    }

    func streamedPages(
        for book: Book,
        provider: any ServerPageProvider,
        mode: ComicPageLoadingMode
    ) async throws -> [URL] {
        let cacheKey = sanitize("\(book.providerId)-\(book.id)")
        let bookDir = cacheRoot.appendingPathComponent(cacheKey, isDirectory: true)

        let pageCount = try await provider.fetchPageCount(for: book)
        try Task.checkCancellation()
        guard pageCount > 0 else {
            throw StreamingError.noPagesFound
        }

        if let previousID = streamIDsByBook[cacheKey], let previous = sources.removeValue(forKey: previousID) {
            retire(streamID: previousID, source: previous, releasingProtection: true)
        }
        let streamID = UUID().uuidString.lowercased()
        streamIDsByBook[cacheKey] = streamID
        sources[streamID] = StreamSource(
            book: book,
            provider: provider,
            cacheDirectory: bookDir,
            pageCount: pageCount,
            mode: mode,
            lease: ReadingCacheWriteLease()
        )

        return (0..<pageCount).compactMap { index in
            URL(string: "enve-comic-page://\(streamID)/\(index)")
        }
    }

    func pageData(at url: URL) async throws -> Data {
        guard url.scheme == "enve-comic-page" else {
            return try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
        }

        guard let (streamID, pageIndex) = streamLocation(for: url),
            sources[streamID] != nil
        else {
            throw StreamingError.invalidPageURL
        }
        return try await loadPage(pageIndex, streamID: streamID, request: .demand).data
    }

    func preparePageWindow(around url: URL) async {
        guard let (streamID, pageIndex) = streamLocation(for: url),
            let source = sources[streamID],
            pageIndex < source.pageCount
        else { return }
        let revision = (windowRevisions[streamID] ?? 0) + 1
        windowRevisions[streamID] = revision

        let window =
            max(0, pageIndex - Self.windowRadius)...min(source.pageCount - 1, pageIndex + Self.windowRadius)
        let wanted = source.mode == .sessionCache ? window.lowerBound...(source.pageCount - 1) : window
        for (key, pageTask) in pageTasks
        where pageTask.streamID == streamID && pageTask.request != .demand && !wanted.contains(pageTask.index) {
            pageTask.task.cancel()
            pageTasks[key] = nil
        }
        if source.mode == .sessionCache {
            let prefetch = prefetches[streamID]
            let filling = window.lowerBound...(window.upperBound + Self.prefetchBatchSize)
            if prefetch.map({ !$0.isFinished && !filling.contains($0.nextIndex) }) ?? true {
                startPrefetch(streamID: streamID, from: window.lowerBound)
            }
        }

        let owner = protectionOwner(streamID)
        await cache.protect(window.map { cachedPageURL(index: $0, in: source.cacheDirectory) }, owner: owner)
        guard isCurrent(source, streamID: streamID) else {
            await cache.release(owner: owner)
            return
        }
        guard windowRevisions[streamID] == revision else { return }

        await withTaskGroup(of: Void.self) { group in
            for index in window {
                group.addTask { [weak self] in
                    _ = await self?.prefetchPage(index, streamID: streamID, request: .window)
                }
            }
        }
    }

    func endSession(for book: Book) {
        let cacheKey = sanitize("\(book.providerId)-\(book.id)")
        guard let streamID = streamIDsByBook.removeValue(forKey: cacheKey),
            let source = sources.removeValue(forKey: streamID)
        else { return }
        retire(streamID: streamID, source: source, releasingProtection: true)
    }

    func retire() async {
        let active = sources
        sources.removeAll()
        streamIDsByBook.removeAll()
        for (streamID, source) in active {
            retire(streamID: streamID, source: source, releasingProtection: false)
            await cache.release(owner: protectionOwner(streamID))
        }
    }

    private func loadPage(_ index: Int, streamID: String, request: PageRequest) async throws -> PageLoad {
        guard let source = sources[streamID], index >= 0, index < source.pageCount else {
            throw StreamingError.invalidPageURL
        }
        let fileURL = cachedPageURL(index: index, in: source.cacheDirectory)
        let key = fileURL.path
        if var existing = pageTasks[key] {
            if request.rank > existing.request.rank {
                existing.request = request
                pageTasks[key] = existing
            }
            return try await existing.task.value
        }

        nextTaskID += 1
        let id = nextTaskID
        let cache = cache
        let generation = cache.clearGeneration
        let task = Task<PageLoad, Error> { [weak self] in
            if let cached = await cache.data(at: fileURL) {
                try Task.checkCancellation()
                guard source.lease.isValid else { throw CancellationError() }
                return PageLoad(data: cached, isCached: true)
            }
            let data = try await source.provider.fetchPage(index + 1, for: source.book)
            // Some providers ignore cancellation; never hand back or store a page for retired work.
            try Task.checkCancellation()
            guard !data.isEmpty, Self.isImage(data) else { throw StreamingError.invalidPageData }

            let current = self?.pageTasks[key].flatMap { $0.id == id ? $0.request : nil } ?? request
            let admission: ReadingCacheAdmission =
                current == .budgetedPrefetch ? .ifRoom(sparing: source.cacheDirectory) : .required
            let isCached =
                (try? await cache.write(data, to: fileURL, lease: source.lease, generation: generation, admission: admission))
                ?? false
            return PageLoad(data: data, isCached: isCached)
        }
        pageTasks[key] = PageTask(id: id, streamID: streamID, index: index, request: request, task: task)
        defer {
            if pageTasks[key]?.id == id {
                pageTasks[key] = nil
            }
        }
        return try await task.value
    }

    // Stop prefetching when the session ends, cancellation arrives or the cache refuses a page.
    private func prefetchPage(_ index: Int, streamID: String, request: PageRequest) async -> Bool {
        guard let source = sources[streamID], index < source.pageCount else { return false }
        let fileURL = cachedPageURL(index: index, in: source.cacheDirectory)
        if pageTasks[fileURL.path] == nil, await cache.hasFile(at: fileURL) {
            return true
        }
        guard !Task.isCancelled, isCurrent(source, streamID: streamID) else { return false }
        do {
            return try await loadPage(index, streamID: streamID, request: request).isCached
        } catch is CancellationError {
            return false
        } catch {
            return isCurrent(source, streamID: streamID)
        }
    }

    private func startPrefetch(streamID: String, from start: Int) {
        prefetches.removeValue(forKey: streamID)?.task.cancel()
        guard let lease = sources[streamID]?.lease else { return }
        nextTaskID += 1
        let id = nextTaskID
        let task = Task { [weak self] in
            var batchStart = start
            while let self, let source = self.sources[streamID], source.lease === lease,
                batchStart < source.pageCount, !Task.isCancelled
            {
                let batch = batchStart...min(batchStart + Self.prefetchBatchSize - 1, source.pageCount - 1)
                let shouldContinue = await withTaskGroup(of: Bool.self) { group in
                    for index in batch {
                        group.addTask { [weak self] in
                            await self?.prefetchPage(index, streamID: streamID, request: .budgetedPrefetch) ?? false
                        }
                    }
                    var admitted = true
                    for await result in group { admitted = admitted && result }
                    return admitted
                }
                guard shouldContinue else { break }
                batchStart = batch.upperBound + 1
                if self.prefetches[streamID]?.id == id {
                    self.prefetches[streamID]?.nextIndex = batchStart
                }
            }
            if self?.prefetches[streamID]?.id == id {
                self?.prefetches[streamID]?.isFinished = true
            }
        }
        prefetches[streamID] = Prefetch(id: id, nextIndex: start, task: task)
    }

    private func retire(streamID: String, source: StreamSource, releasingProtection: Bool) {
        windowRevisions[streamID] = nil
        source.lease.revoke()
        prefetches.removeValue(forKey: streamID)?.task.cancel()
        for (key, pageTask) in pageTasks where pageTask.streamID == streamID {
            pageTask.task.cancel()
            pageTasks[key] = nil
        }
        guard releasingProtection else { return }
        let cache = cache
        let owner = protectionOwner(streamID)
        Task { await cache.release(owner: owner) }
    }

    private func isCurrent(_ source: StreamSource, streamID: String) -> Bool {
        sources[streamID]?.lease === source.lease
    }

    private func protectionOwner(_ streamID: String) -> String {
        "comic-stream-\(streamID)"
    }

    private func streamLocation(for url: URL) -> (streamID: String, pageIndex: Int)? {
        guard url.scheme == "enve-comic-page",
            let streamID = url.host,
            let pageIndex = Int(url.lastPathComponent),
            pageIndex >= 0
        else { return nil }
        return (streamID, pageIndex)
    }

    private func cachedPageURL(index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "%05d.page", index))
    }

    private func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
    }

    // Reject non-image responses before caching them as comic pages.
    private nonisolated static func isImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetType(source) != nil && CGImageSourceGetCount(source) > 0
    }

    enum StreamingError: LocalizedError {
        case noPagesFound
        case invalidPageURL
        case invalidPageData

        var errorDescription: String? {
            switch self {
            case .noPagesFound: return "Server returned no pages for this book"
            case .invalidPageURL: return "The streamed comic page URL is invalid"
            case .invalidPageData: return "The server didn't return a readable comic page."
            }
        }
    }

    // Only window prefetch can evict pages; demand survives window changes and budgeted prefetch uses free space.
    private enum PageRequest {
        case budgetedPrefetch, window, demand

        var rank: Int {
            switch self {
            case .budgetedPrefetch: 0
            case .window: 1
            case .demand: 2
            }
        }
    }

    private struct PageLoad {
        let data: Data
        let isCached: Bool
    }

    private struct PageTask {
        let id: Int
        let streamID: String
        let index: Int
        var request: PageRequest
        let task: Task<PageLoad, Error>
    }

    private struct Prefetch {
        let id: Int
        var nextIndex: Int
        var isFinished = false
        let task: Task<Void, Never>
    }

    private struct StreamSource {
        let book: Book
        let provider: any ServerPageProvider
        let cacheDirectory: URL
        let pageCount: Int
        let mode: ComicPageLoadingMode
        let lease: ReadingCacheWriteLease
    }
}
