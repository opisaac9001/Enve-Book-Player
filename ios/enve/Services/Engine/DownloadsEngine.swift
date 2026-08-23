import Combine
import Foundation

enum DownloadedStorageKind: String, Sendable {
    case audiobook
    case ebook
}

struct DownloadedStorageItem: Identifiable, Sendable {
    let id: String
    let kind: DownloadedStorageKind
    let storageKey: String
    let book: Book?
    let title: String
    let subtitle: String?
    let sizeBytes: Int64
}

@MainActor
@Observable
final class DownloadsEngine {
    private let service: UnifiedDownloadService
    private let appState: AppState
    private var cancellables: Set<AnyCancellable> = []
    private var revision = 0

    init(
        service: UnifiedDownloadService = .shared,
        appState: AppState = .shared
    ) {
        self.service = service
        self.appState = appState
        service.objectWillChange
            .sink { [weak self] _ in
                self?.revision &+= 1
            }
            .store(in: &cancellables)
    }

    var tasks: [BookDownloadTask] {
        _ = revision
        return service.tasks
    }

    var activeTasks: [BookDownloadTask] {
        tasks.filter(\.isActive)
    }

    var failedTasks: [BookDownloadTask] {
        tasks.filter { $0.status == .failed }
    }

    var completedTasks: [BookDownloadTask] {
        tasks.filter { $0.status == .completed }
    }

    var isCellularWithDownloadsDisabled: Bool {
        _ = revision
        return service.isCellularWithDownloadsDisabled
    }

    var isNetworkAvailable: Bool {
        _ = revision
        return service.isNetworkAvailable
    }

    var completedDownloadBookIds: Set<String> {
        var ids = Set(service.completedTasks.map(\.bookId))
        ids.formUnion(BookDownloadManager.shared.completedBookIds)
        return ids
    }

    func mostRelevantTask(for book: Book) -> BookDownloadTask? {
        tasks
            .filter { $0.bookId == book.downloadKey }
            .sorted { lhs, rhs in
                let lhsRank = lhs.isActive ? 0 : 1
                let rhsRank = rhs.isActive ? 0 : 1
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.updatedAt > rhs.updatedAt
            }
            .first
    }

    func isDownloaded(_ book: Book) -> Bool {
        if usesReaderDownload(book) {
            return LocalEbookImporter.shared.persistedRemoteEbook(forBookId: book.id) != nil
                || LocalEbookImporter.shared.cachedReadaloudEpub(forBookId: book.id) != nil
                || book.ebookFileURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
        }
        return LocalStorageManager.shared.isAudiobookDownloaded(book)
    }

    func isLibraryDownloaded(_ book: Book) -> Bool {
        book.mediaType == .ebook
            ? hasPermanentEbookDownload(book)
            : LocalStorageManager.shared.isAudiobookDownloaded(book)
    }

    func isAudiobookDownloaded(_ book: Book) -> Bool {
        _ = revision
        return LocalStorageManager.shared.isAudiobookDownloaded(book)
    }

    func isAudiobookDownloaded(downloadKey: String) -> Bool {
        _ = revision
        return LocalStorageManager.shared.isAudiobookDownloaded(downloadKey)
    }

    func hasPermanentEbookDownload(_ book: Book) -> Bool {
        guard book.mediaType == .ebook else { return false }
        let importer = LocalEbookImporter.shared

        if book.source == .local {
            return importer.resolveExistingLocalEbookURL(
                bookIdentifier: book.id,
                ebookFileURL: book.ebookFileURL,
                filePath: book.filePath
            ) != nil
        }

        if importer.persistedRemoteEbook(forBookId: book.id) != nil {
            return true
        }

        guard let url = book.ebookFileURL, FileManager.default.fileExists(atPath: url.path) else {
            return false
        }
        return url.path.hasPrefix(importer.serverEbooksRoot.path)
            || url.path.hasPrefix(importer.readaloudCacheRoot.path)
    }

    func usesReaderDownload(_ book: Book) -> Bool {
        book.mediaType == .ebook || (book.source == .storyteller && book.epub3Features?.hasMediaOverlay == true)
    }

    func cancel(taskId: String) {
        service.cancel(taskId: taskId)
    }

    func pause(taskId: String) {
        service.pause(taskId: taskId)
    }

    func resume(taskId: String, book: Book) async {
        await service.resume(taskId: taskId, book: book)
    }

    func retry(taskId: String, book: Book) async {
        await service.retry(taskId: taskId, book: book)
    }

    func remove(taskId: String) {
        service.remove(taskId: taskId)
    }

    func clearCompleted() {
        service.clearCompleted()
    }

    func deleteDownload(bookId: String) async {
        await service.deleteDownload(bookId: bookId)
    }

    func checkStorageLimit() async {
        await service.checkStorageLimit()
    }

    func downloadedStorageItems() async -> [DownloadedStorageItem] {
        let storage = LocalStorageManager.shared
        let downloadedIds = storage.downloadedAudiobookIds()
        let liveBooks = await appState.bookStore.allBooks()
        let downloadedEbooks = await appState.bookStore.downloadedEbooks(limit: max(liveBooks.count, 1))
        let liveByKey = Dictionary(
            liveBooks.map { (Self.sanitizeDownloadKey($0.downloadKey), $0) },
            uniquingKeysWith: { _, new in new }
        )
        let recentByKey = Dictionary(
            BookProgressStore.shared.loadRecentlyPlayed().map { (Self.sanitizeDownloadKey($0.downloadKey), $0) },
            uniquingKeysWith: { _, new in new }
        )

        let audiobooks: [DownloadedStorageItem] = downloadedIds.compactMap { id -> DownloadedStorageItem? in
            let size = storage.sizeOfAudiobook(id)
            guard size > 0 else { return nil }
            let book = liveByKey[id] ?? recentByKey[id]
            return DownloadedStorageItem(
                id: "\(DownloadedStorageKind.audiobook.rawValue):\(id)",
                kind: .audiobook,
                storageKey: id,
                book: book,
                title: book?.title ?? "Downloaded audiobook",
                subtitle: book?.author,
                sizeBytes: size
            )
        }

        let importer = LocalEbookImporter.shared
        var seenPaths = Set<String>()
        let ebookSeeds = downloadedEbooks.compactMap { book -> (Book, URL)? in
            guard book.mediaType == .ebook, book.source != .local else { return nil }
            let url = importer.persistedRemoteEbook(forBookId: book.id) ?? book.ebookFileURL
            guard let url,
                FileManager.default.fileExists(atPath: url.path),
                Self.isContained(url, in: importer.serverEbooksRoot)
            else { return nil }
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { return nil }
            return (book, url)
        }
        let ebooks = await Task.detached(priority: .utility) {
            ebookSeeds.compactMap { book, url -> DownloadedStorageItem? in
                let size = Self.sizeOfItem(at: url)
                guard size > 0 else { return nil }
                return DownloadedStorageItem(
                    id: "\(DownloadedStorageKind.ebook.rawValue):\(book.uniqueId)",
                    kind: .ebook,
                    storageKey: book.id,
                    book: book,
                    title: book.title,
                    subtitle: book.author,
                    sizeBytes: size
                )
            }
        }.value

        return (audiobooks + ebooks)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func downloadedStorageBytes() async -> Int64 {
        await downloadedStorageItems().reduce(0) { $0 + $1.sizeBytes }
    }

    func deleteStorageItem(_ item: DownloadedStorageItem) async {
        switch item.kind {
        case .audiobook:
            _ = LocalStorageManager.shared.deleteAudiobook(item.storageKey)
            revision &+= 1
        case .ebook:
            guard let book = item.book else { return }
            await removeLibraryDownload(for: book)
        }
    }

    func deleteAudiobookDownload(id: String) {
        _ = LocalStorageManager.shared.deleteAudiobook(id)
        revision &+= 1
    }

    func download(_ book: Book, overrideCellular: Bool = false) async {
        await service.download(book: book, overrideCellular: overrideCellular)
    }

    func downloadFileCopy(bookId: String, title: String, sourceURL: URL) async {
        await service.downloadFileCopy(bookId: bookId, title: title, sourceURL: sourceURL)
    }

    func removeDownload(for book: Book) async {
        if usesReaderDownload(book) {
            try? LocalEbookImporter.shared.deleteRemoteEbookArtifacts(forBookId: book.id)
            LocalEbookImporter.shared.removeReadaloudCache(forBookId: book.id, stableId: book.stableId)
            if let url = AppState.shared.bookInMemory(uniqueId: book.uniqueId)?.ebookFileURL {
                let managed =
                    url.path.hasPrefix(LocalEbookImporter.shared.serverEbooksRoot.path)
                    || url.path.hasPrefix(LocalEbookImporter.shared.remoteReaderCacheRoot.path)
                    || url.path.hasPrefix(LocalEbookImporter.shared.readaloudCacheRoot.path)
                if managed {
                    AppState.shared.mutateBook(uniqueId: book.uniqueId) { $0.ebookFileURL = nil }
                }
            }
            NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
            revision &+= 1
        } else {
            await service.deleteDownload(book: book)
        }
    }

    func removeLibraryDownload(for book: Book) async {
        if book.mediaType == .ebook {
            guard book.source != .local else { return }
            try? LocalEbookImporter.shared.deleteRemoteEbookArtifacts(forBookId: book.id)
            LocalEbookImporter.shared.removeReadaloudCache(forBookId: book.id, stableId: book.stableId)
            if let url = AppState.shared.bookInMemory(uniqueId: book.uniqueId)?.ebookFileURL ?? book.ebookFileURL {
                let managed =
                    url.path.hasPrefix(LocalEbookImporter.shared.serverEbooksRoot.path)
                    || url.path.hasPrefix(LocalEbookImporter.shared.remoteReaderCacheRoot.path)
                if managed {
                    AppState.shared.mutateBook(uniqueId: book.uniqueId) { $0.ebookFileURL = nil }
                }
            }
            NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
            revision &+= 1
        } else {
            await service.deleteDownload(book: book)
        }
    }

    private static func sanitizeDownloadKey(_ key: String) -> String {
        key
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "?", with: "-")
            .replacingOccurrences(of: "&", with: "-")
            .replacingOccurrences(of: "=", with: "-")
    }

    nonisolated private static func isContained(_ url: URL, in root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    nonisolated private static func sizeOfItem(at url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true {
            return Int64(values.fileSize ?? 0)
        }

        guard
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        else { return 0 }

        var total: Int64 = 0
        while let fileURL = enumerator.nextObject() as? URL {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}
