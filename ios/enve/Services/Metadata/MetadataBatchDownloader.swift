import Combine
import Foundation
import Logging

#if os(iOS)
import UIKit
#endif

final class MetadataBatchDownloader: NSObject, ObservableObject, @unchecked Sendable {
    static let shared = MetadataBatchDownloader()

    @Published private(set) var queue: [DownloadItem] = []
    @Published private(set) var isDownloading = false

    private let persistence = DownloadPersistence.shared
    private let networkPolicyService = NetworkPolicyService.shared
    private let settingsManager = SettingsManager.shared

    private var urlSession: URLSession?
    private var delegateQueue = DispatchQueue(label: "com.narrator.MetadataBatchDownloader.delegate")
    private var stateQueue = DispatchQueue(label: "com.narrator.MetadataBatchDownloader.state", attributes: .concurrent)

    nonisolated(unsafe) private var activeBatches: [String: URLSessionDataTask] = [:]
    private var taskToItemMapping: [Int: String] = [:]
    nonisolated(unsafe) private var cancelledItems: Set<String> = []

    private var metadataCache: [String: Data] = [:]

    private override init() {
        super.init()
        restoreQueueFromDisk()
    }

    private func setupSession() {
        if urlSession == nil {
            let config = networkPolicyService.makeBackgroundSessionConfiguration(
                identifier: "com.narrator.metadata-downloads",
                allowCellular: settingsManager.allowCellularMetadataDownloads
            )
            urlSession = URLSession(
                configuration: config,
                delegate: self,
                delegateQueue: OperationQueue.main
            )
        }
    }

    func loadQueue() {
        restoreQueueFromDisk()

        setupSession()
    }

    func createBatchDownload(title: String, destinationPath: String) -> DownloadItem {
        return DownloadItem.newMetadataBatch(title: title, destinationPath: destinationPath)
    }

    func enqueueBatchDownload(_ item: DownloadItem) async {
        guard networkPolicyService.canDownload(allowCellular: settingsManager.allowCellularMetadataDownloads) else {
            var errorItem = item
            errorItem.status = .failed
            errorItem.errorDescription = "Network unavailable or cellular not allowed"
            await updateItem(errorItem)
            return
        }

        setupSession()

        var newItem = item
        newItem.status = .pending

        await MainActor.run {
            self.queue.append(newItem)
            self.objectWillChange.send()
        }

        startBatchIfNeeded()
    }

    func startBatch(_ id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }

        setupSession()
        stateQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.queue[index].status = .downloading
                self.isDownloading = true
                self.objectWillChange.send()
            }
        }

        startBatchIfNeeded()
    }

    func pauseBatch(_ id: String) {
        if let task = activeBatches[id] {
            task.suspend()
        }

        if let index = queue.firstIndex(where: { $0.id == id }) {
            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.queue[index].status = .paused
                }
            }
        }
    }

    func resumeBatch(_ id: String) {
        if let task = activeBatches[id] {
            task.resume()
        }

        if let index = queue.firstIndex(where: { $0.id == id }) {
            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.queue[index].status = .downloading
                    self.isDownloading = true
                }
            }
        }
    }

    func cancelBatch(_ id: String) {
        if let task = activeBatches.removeValue(forKey: id) {
            task.cancel()
        }

        stateQueue.async(flags: .barrier) { [weak self] in
            self?.cancelledItems.insert(id)
        }

        if let index = queue.firstIndex(where: { $0.id == id }) {
            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.queue[index].status = .cancelled
                }
            }
        }

        updateIsDownloading()
    }

    private func startBatchIfNeeded() {
        let pendingItems = queue.filter { $0.status == .pending }
        let activeCount = queue.filter { $0.status == .downloading }.count

        guard activeCount == 0, !pendingItems.isEmpty else { return }

        for item in pendingItems {
            startBatchFetch(item)
        }
    }

    private func startBatchFetch(_ item: DownloadItem) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return }

        stateQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.queue[index].status = .downloading
                self.objectWillChange.send()
            }
        }

        Task {
            do {
                try await fetchMetadataForAllBooks(itemId: item.id)
            } catch {
                await failBatch(item.id, withError: error)
            }
        }
    }

    private func fetchMetadataForAllBooks(itemId: String) async throws {
        var allBooks: [Book] = []

        let recentBooks = BookProgressStore.shared.loadRecentlyPlayed()
        allBooks.append(contentsOf: recentBooks)

        let connections = await MainActor.run { AppState.shared.providerConnections.connections }
        for connection in connections {
            if let books = await fetchBooksFromConnection(connection) {
                let existingIds = Set(allBooks.map { $0.stableId })
                let newBooks = books.filter { !existingIds.contains($0.stableId) }
                allBooks.append(contentsOf: newBooks)
            }
        }

        let localBooks = await fetchLocalLibraryBooks()
        let existingIds = Set(allBooks.map { $0.stableId })
        let newLocalBooks = localBooks.filter { !existingIds.contains($0.stableId) }
        allBooks.append(contentsOf: newLocalBooks)

        guard !allBooks.isEmpty else {
            throw NSError(
                domain: "MetadataBatchDownloader",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No books found. Play some books first or load your library."]
            )
        }

        AppLogger.network.info("Aggregated \(allBooks.count) books from all sources")

        let totalBooks = allBooks.count
        var processedBooks = 0

        if let index = queue.firstIndex(where: { $0.id == itemId }) {
            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.queue[index].bytesDownloaded = 0
                    self.queue[index].totalBytes = Int64(totalBooks)
                    self.objectWillChange.send()
                }
            }
        }

        let batchSize = 10
        for batchStart in stride(from: 0, to: allBooks.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, allBooks.count)
            let batch = Array(allBooks[batchStart..<batchEnd])

            await processBatch(batch, itemId: itemId)

            processedBooks += batch.count

            if let index = queue.firstIndex(where: { $0.id == itemId }) {
                let currentProgress = Int64(processedBooks)
                stateQueue.async(flags: .barrier) { [weak self] in
                    guard let self else { return }
                    Task { @MainActor in
                        self.queue[index].bytesDownloaded = currentProgress
                        self.objectWillChange.send()
                    }
                }
            }

            try await Task.sleep(nanoseconds: 500_000_000)
        }

        if let index = queue.firstIndex(where: { $0.id == itemId }) {
            var item = queue[index]
            item.status = .completed
            item.errorDescription = nil
            item.lastUpdated = Date()

            await updateItem(item)
            updateIsDownloading()
        }
    }

    private func processBatch(_ books: [Book], itemId: String) async {
        guard let index = queue.firstIndex(where: { $0.id == itemId }),
            queue[index].status == .downloading
        else {
            return
        }

        let audibleService = AudibleService.shared

        for book in books {
            if let asin = book.asin, !asin.isEmpty {
                continue
            }

            do {
                if let author = book.author {
                    let searchResults = try await audibleService.simpleSearch(
                        query: "\(book.title) \(author)",
                        numResults: 5
                    )

                    if let firstMatch = searchResults.first {
                        AppLogger.network.debug(
                            "Found metadata candidate bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) asinId=\(DiagnosticLogSanitizer.identifier(for: firstMatch.asin))"
                        )

                    }
                }
            } catch {
                AppLogger.network.error(
                    "Failed to fetch metadata bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error)"
                )
            }

            guard let idx = queue.firstIndex(where: { $0.id == itemId }),
                queue[idx].status == .downloading
            else {
                break
            }
        }
    }

    private func completeBatch(_ itemId: String) {
        guard let index = queue.firstIndex(where: { $0.id == itemId }) else { return }

        var item = queue[index]
        item.status = .completed
        item.errorDescription = nil
        item.lastUpdated = Date()

        stateQueue.async(flags: .barrier) { [weak self] in
            self?.activeBatches.removeValue(forKey: itemId)
        }

        Task { await updateItem(item) }
        updateIsDownloading()
    }

    private func failBatch(_ itemId: String, withError error: Error) async {
        guard let index = queue.firstIndex(where: { $0.id == itemId }) else { return }

        var item = queue[index]
        item.status = .failed
        item.errorDescription = error.localizedDescription
        item.lastUpdated = Date()

        stateQueue.async(flags: .barrier) { [weak self] in
            self?.activeBatches.removeValue(forKey: itemId)
        }

        await updateItem(item)
        updateIsDownloading()
    }

    private func updateItem(_ item: DownloadItem) async {
        if let index = queue.firstIndex(where: { $0.id == item.id }) {
            stateQueue.async(flags: .barrier) { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.queue[index] = item
                }
            }
        }

        do {
            var loadedQueue = persistence.loadMetadataDownloadQueue()
            loadedQueue.updateItem(item)
            try persistence.saveMetadataDownloadQueue(loadedQueue)
        } catch {
            AppLogger.network.error("Failed to update metadata download: \(error)")
        }

        DispatchQueue.main.async {
            self.objectWillChange.send()
        }

        updateIsDownloading()
    }

    private func restoreQueueFromDisk() {
        let loaded = persistence.loadMetadataDownloadQueue()
        Task { @MainActor in
            self.queue = loaded.items
        }
    }

    private func updateIsDownloading() {
        let hasActive = queue.contains { $0.status == .downloading || $0.status == .pending }
        DispatchQueue.main.async {
            self.isDownloading = hasActive
            self.objectWillChange.send()
        }
    }

    private func fetchBooksFromConnection(_ connection: ServerConnection) async -> [Book]? {
        do {
            switch connection.type {
            case .audiobookshelf:
                let provider = AudiobookshelfProvider(connection: connection)
                let libraries = try await provider.fetchLibraries()
                var books: [Book] = []
                for library in libraries {
                    if let libraryBooks = try? await provider.fetchBooks(libraryId: library.id) {
                        books.append(contentsOf: libraryBooks)
                    }
                }
                return books.isEmpty ? nil : books

            case .plex:
                return nil

            case .jellyfin:
                let provider = JellyfinProvider(connection: connection)
                let libraries = try await provider.fetchLibraries()
                var books: [Book] = []
                for library in libraries {
                    if let libraryBooks = try? await provider.fetchBooks(libraryId: library.id) {
                        books.append(contentsOf: libraryBooks)
                    }
                }
                return books.isEmpty ? nil : books

            case .emby:
                let provider = EmbyProvider(connection: connection)
                let libraries = try await provider.fetchLibraries()
                var books: [Book] = []
                for library in libraries {
                    if let libraryBooks = try? await provider.fetchBooks(libraryId: library.id) {
                        books.append(contentsOf: libraryBooks)
                    }
                }
                return books.isEmpty ? nil : books

            case .webdav, .torbox:
                let provider = WebDAVProvider(connection: connection)
                let libraries = try await provider.fetchLibraries()
                var books: [Book] = []
                for library in libraries {
                    if let libraryBooks = try? await provider.fetchBooks(libraryId: library.id) {
                        books.append(contentsOf: libraryBooks)
                    }
                }
                return books.isEmpty ? nil : books

            default:
                return nil
            }
        } catch {
            AppLogger.network.error(
                "Failed to fetch providerId=\(DiagnosticLogSanitizer.identifier(for: connection.id.uuidString)): \(error)"
            )
            return nil
        }
    }

    private func fetchLocalLibraryBooks() async -> [Book] {
        return []
    }
}

extension MetadataBatchDownloader: URLSessionDataDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let key = "\(dataTask.taskIdentifier)"
        let capturedData = data
        Task { @MainActor in
            if self.metadataCache[key] != nil {
                self.metadataCache[key]?.append(capturedData)
            } else {
                self.metadataCache[key] = capturedData
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let key = "\(task.taskIdentifier)"
        let taskId = task.taskIdentifier
        let capturedError = error

        Task { @MainActor in
            self.metadataCache.removeValue(forKey: key)

            if let error = capturedError {
                if (error as NSError).code != NSURLErrorCancelled {
                    if let itemId = self.taskToItemMapping[taskId] {
                        await self.failBatch(itemId, withError: error)
                    }
                }
            }

            self.taskToItemMapping.removeValue(forKey: taskId)
        }
    }

    func registerTask(_ task: URLSessionDataTask, forItemId itemId: String) {
        taskToItemMapping[task.taskIdentifier] = itemId
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in
            #if os(iOS)
            guard let delegate = UIApplication.shared.delegate as? CarPlayAppDelegate else { return }
            delegate.consumeBackgroundCompletionHandler(forIdentifier: identifier)?()
            #endif
        }
    }
}
