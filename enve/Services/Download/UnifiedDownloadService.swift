import AVFoundation
import Combine
import Foundation
import Logging
import Network

#if canImport(UIKit)
import UIKit
#endif

struct BookDownloadTask: Identifiable, Codable {
    let id: String
    let bookId: String
    let title: String
    let source: Book.BookSource
    var status: DownloadStatus
    var progress: Double
    var bytesDownloaded: Int64
    var totalBytes: Int64
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    enum DownloadStatus: String, Codable {
        case queued
        case downloading
        case paused
        case completed
        case failed
        case cancelled
    }

    var isActive: Bool {
        status == .queued || status == .downloading
    }

    var progressText: String {
        if totalBytes > 0 {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let downloaded = formatter.string(fromByteCount: bytesDownloaded)
            let total = formatter.string(fromByteCount: totalBytes)
            return "\(Int(progress * 100))% (\(downloaded) / \(total))"
        }
        return "\(Int(progress * 100))%"
    }

    static func create(bookId: String, title: String, source: Book.BookSource) -> BookDownloadTask {
        BookDownloadTask(
            id: UUID().uuidString,
            bookId: bookId,
            title: title,
            source: source,
            status: .queued,
            progress: 0,
            bytesDownloaded: 0,
            totalBytes: 0,
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}

@MainActor
protocol DownloadLibraryCaching: AnyObject {
    func bookInMemory(uniqueId: String) -> Book?

    @discardableResult
    func mutateBook(uniqueId: String, _ transform: (inout Book) -> Void) -> Book?
}

extension AppState: DownloadLibraryCaching {}

@MainActor
final class UnifiedDownloadService: NSObject, ObservableObject {
    static let shared: UnifiedDownloadService = {
        let appState = AppState.shared
        return UnifiedDownloadService(
            providerConnections: appState.providerConnections,
            presentation: appState.presentation,
            bookQuerying: appState.bookStore,
            bookWriting: appState.bookStore,
            libraryCache: appState
        )
    }()
    static let backgroundSessionIdentifier = "com.narrator.downloads"

    @Published private(set) var tasks: [BookDownloadTask] = [] {
        didSet {

            activeTaskBookIdsMirrorLock.lock()
            let activeTasks = tasks.filter { $0.isActive }
            activeTaskBookIdsMirror = Set(activeTasks.map { $0.bookId })
            activeTaskIdsMirror = Dictionary(uniqueKeysWithValues: activeTasks.map { ($0.id, $0.bookId) })
            activeTaskBookIdsMirrorLock.unlock()
        }
    }
    @Published private(set) var isNetworkAvailable: Bool = true
    @Published private(set) var isOnCellular: Bool = false
    @Published var lastError: String?

    private let activeTaskBookIdsMirrorLock = NSLock()
    nonisolated(unsafe) private var activeTaskBookIdsMirror: Set<String> = []
    nonisolated(unsafe) private var activeTaskIdsMirror: [String: String] = [:]

    nonisolated func hasActiveTaskForBookId(_ bookId: String) -> Bool {
        activeTaskBookIdsMirrorLock.lock()
        defer { activeTaskBookIdsMirrorLock.unlock() }
        return activeTaskBookIdsMirror.contains(bookId)
    }

    nonisolated private func isActiveDownloadTask(taskId: String, bookId: String) -> Bool {
        activeTaskBookIdsMirrorLock.lock()
        defer { activeTaskBookIdsMirrorLock.unlock() }
        return activeTaskIdsMirror[taskId] == bookId
    }

    nonisolated private func diagnosticID(_ value: String) -> String {
        DiagnosticLogSanitizer.identifier(for: value)
    }

    var allowCellularDownloads: Bool {
        SettingsManager.shared.allowCellularBookDownloads
    }

    var activeTasks: [BookDownloadTask] { tasks.filter { $0.isActive } }
    var completedTasks: [BookDownloadTask] { tasks.filter { $0.status == .completed } }
    var failedTasks: [BookDownloadTask] { tasks.filter { $0.status == .failed } }
    var activeCount: Int { activeTasks.count }

    var overallProgress: Double {
        let active = activeTasks
        guard !active.isEmpty else { return 0 }
        let total = active.reduce(0.0) { $0 + $1.progress }
        return total / Double(active.count)
    }

    var canDownload: Bool {
        guard isNetworkAvailable else { return false }
        if isOnCellular && !allowCellularDownloads { return false }
        return true
    }

    var downloadBlockedReason: String? {
        if !isNetworkAvailable { return "No network connection" }
        if isOnCellular && !allowCellularDownloads { return "Cellular downloads disabled in Settings" }
        return nil
    }

    var networkMonitorCurrentPath: NWPath {
        networkMonitor.currentPath
    }

    var isCellularWithDownloadsDisabled: Bool {
        let path = networkMonitor.currentPath
        return path.isExpensive && !allowCellularDownloads
    }

    private var urlSession: URLSession!
    private var foregroundURLSession: URLSession!
    private var activeURLTasks: [String: URLSessionDownloadTask] = [:]
    private var readerAssetOperations: [String: (id: UUID, task: Task<URL, Error>)] = [:]
    private var storytellerReadaloudCacheTasks: [String: (id: UUID, task: Task<URL, Error>)] = [:]
    private var expectedBytesByTaskId: [String: Int64] = [:]
    private var resumeData: [String: Data] = [:]
    private var lastProgressEmissionByTaskId: [String: (time: Date, progress: Double)] = [:]
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.narrator.download.network")
    private let storageManager = LocalStorageManager.shared
    private let destinations = DownloadDestinationFileSystem(
        audiobooksRoot: LocalStorageManager.shared.audiobooksDirectory
    )
    let providerConnections: any ProviderConnectionAccessing
    private let presentation: AppPresentationState
    private let bookQuerying: any BookQuerying
    private let bookWriting: any BookWriting
    private let libraryCache: any DownloadLibraryCaching
    private let queueStore = UnifiedDownloadQueueStore()
    private let minProgressUpdateInterval: TimeInterval = 0.25
    private let minProgressDelta: Double = 0.005

    static let downloadCompletedNotification = Notification.Name("UnifiedDownloadCompleted")
    static let downloadFailedNotification = Notification.Name("UnifiedDownloadFailed")

    private init(
        providerConnections: any ProviderConnectionAccessing,
        presentation: AppPresentationState,
        bookQuerying: any BookQuerying,
        bookWriting: any BookWriting,
        libraryCache: any DownloadLibraryCaching
    ) {
        self.providerConnections = providerConnections
        self.presentation = presentation
        self.bookQuerying = bookQuerying
        self.bookWriting = bookWriting
        self.libraryCache = libraryCache
        super.init()

        loadQueue()

        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        let foregroundConfig = URLSessionConfiguration.default
        foregroundConfig.allowsCellularAccess = true
        foregroundConfig.waitsForConnectivity = true
        foregroundConfig.timeoutIntervalForRequest = 600
        foregroundConfig.timeoutIntervalForResource = 7200
        foregroundURLSession = URLSession(configuration: foregroundConfig, delegate: self, delegateQueue: nil)

        setupNetworkMonitor()

        Task { [weak self] in
            await self?.cleanupFailedDownloads()
            await self?.checkStorageLimit()
        }

        AppLogger.network.info("UnifiedDownloadService initialized")
    }

    private func setupNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let isAvailable = path.status == .satisfied
            let isExpensive = path.isExpensive
            Task { @MainActor [weak self] in
                self?.isNetworkAvailable = isAvailable
                self?.isOnCellular = isExpensive
                AppLogger.network.info("Network: available=\(isAvailable), cellular=\(isExpensive)")
            }
        }
        networkMonitor.start(queue: monitorQueue)

        AppLogger.network.info("Network monitor started, waiting for first update...")
    }

    private func loadQueue() {
        let restored = queueStore.load()
        guard !restored.isEmpty else { return }
        tasks = restored
        AppLogger.network.info("Loaded \(restored.count) download tasks from storage")
    }

    private func saveQueue() {
        queueStore.save(tasks)
    }

    private func updateTask(_ taskId: String, persist: Bool = true, update: (inout BookDownloadTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }

        var updatedTasks = tasks
        var task = updatedTasks[index]
        update(&task)
        task.updatedAt = Date()
        updatedTasks[index] = task
        tasks = updatedTasks

        if persist {
            saveQueue()
        }
    }

    private func shouldEmitProgressUpdate(taskId: String, progress: Double) -> Bool {
        let now = Date()
        if let last = lastProgressEmissionByTaskId[taskId] {
            let delta = abs(progress - last.progress)
            let elapsed = now.timeIntervalSince(last.time)
            if delta < minProgressDelta && elapsed < minProgressUpdateInterval {
                return false
            }
        }
        lastProgressEmissionByTaskId[taskId] = (now, progress)
        return true
    }

    func download(book: Book, overrideCellular: Bool = false) async {
        lastError = nil

        let bookId = book.downloadKey

        let isSMBBook = book.source == .smb

        if !isSMBBook && storageManager.isAudiobookDownloaded(bookId) {
            AppLogger.network.debug("Book already downloaded diagnosticID=\(diagnosticID(book.stableId))")
            return
        }

        tasks.removeAll { $0.bookId == bookId && ($0.status == .completed || $0.status == .failed || $0.status == .cancelled) }

        let hasActiveTaskEntry = tasks.contains(where: { $0.bookId == bookId && $0.isActive })
        if hasActiveTaskEntry {
            let hasLiveURLTask = activeURLTasks[bookId] != nil
            let hasLiveExternalTask = BookDownloadManager.shared.activeBookIds.contains(bookId)

            if !hasLiveURLTask && !hasLiveExternalTask {
                tasks.removeAll { $0.bookId == bookId && $0.isActive }
                AppLogger.network.debug("Removed stale active download task diagnosticID=\(diagnosticID(book.stableId))")
            }
        }

        if tasks.contains(where: { $0.bookId == bookId && $0.isActive }) {
            AppLogger.network.debug("Book already in download queue diagnosticID=\(diagnosticID(book.stableId))")
            saveQueue()
            return
        }

        if isSMBBook {
            saveQueue()
        }

        let currentPath = networkMonitor.currentPath
        let networkAvailable = currentPath.status == .satisfied
        let onCellular = currentPath.isExpensive

        AppLogger.network.info("Network check at download: available=\(networkAvailable), cellular=\(onCellular)")

        if !networkAvailable {
            lastError = "No network connection"
            AppLogger.network.error("Cannot download: No network connection")
            return
        }

        if onCellular && !allowCellularDownloads && !overrideCellular {
            lastError = "Cellular downloads disabled in Settings"
            AppLogger.network.error("Cannot download: Cellular downloads disabled")
            return
        }

        isNetworkAvailable = networkAvailable
        isOnCellular = onCellular

        var task = BookDownloadTask.create(bookId: bookId, title: book.title, source: book.source)
        tasks.append(task)
        saveQueue()

        AppLogger.network.debug("Added to download queue diagnosticID=\(diagnosticID(book.stableId))")

        await startDownload(task: &task, book: book)
    }

    func existingReaderAsset(for book: Book) -> URL? {
        if book.epub3Features?.hasMediaOverlay == true,
            let readaloud = LocalEbookImporter.shared.resolveEbookForOverlay(book: book)
        {
            return readaloud
        }
        return LocalEbookImporter.shared.resolveExistingLocalEbookURL(
            bookIdentifier: book.id,
            ebookFileURL: book.ebookFileURL,
            filePath: book.mediaType == .ebook ? book.filePath : nil
        )
    }

    func prepareReaderAsset(
        for book: Book,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        if let existing = existingReaderAsset(for: book) {
            return existing
        }

        if book.source == .storyteller, book.epub3Features?.hasMediaOverlay == true {
            return try await ensureStorytellerReadaloudCached(for: book, onProgress: onProgress)
        }

        guard book.mediaType == .ebook || book.hasAlternateFormat else {
            throw NSError(
                domain: "UnifiedDownloadService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "This book does not include a readable ebook format."]
            )
        }

        if let operation = readerAssetOperations[book.uniqueId] {
            return try await operation.task.value
        }

        guard let provider = providerConnections.capability(EbookDownloadProvider.self, for: book) else {
            throw DownloadError.missingCredentials("No active connection found for this server")
        }

        let operationId = UUID()
        let operation = Task<URL, Error> {

            let downloadedURL = try await provider.downloadEbook(for: book, onProgress: onProgress)
            try Task.checkCancellation()
            try Self.validateDownloadedEbook(downloadedURL)
            return downloadedURL
        }
        readerAssetOperations[book.uniqueId] = (operationId, operation)

        do {
            let assetURL = try await operation.value
            if readerAssetOperations[book.uniqueId]?.id == operationId {
                readerAssetOperations[book.uniqueId] = nil
            }
            return assetURL
        } catch {
            if readerAssetOperations[book.uniqueId]?.id == operationId {
                readerAssetOperations[book.uniqueId] = nil
            }
            throw error
        }
    }

    func cancelReaderAssetPreparation(for book: Book) {
        readerAssetOperations[book.uniqueId]?.task.cancel()
        if !tasks.contains(where: { $0.bookId == book.downloadKey && $0.isActive }) {
            storytellerReadaloudCacheTasks[book.uniqueId]?.task.cancel()
        }
    }

    @discardableResult
    func ensureStorytellerReadaloudCached(
        for book: Book,
        provider suppliedProvider: StorytellerProvider? = nil,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        prepareForOfflinePlayback: Bool = false
    ) async throws -> URL {
        guard book.source == .storyteller, book.epub3Features?.hasMediaOverlay == true else {
            throw NSError(
                domain: "UnifiedDownloadService",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "This Storyteller book is not a read-aloud EPUB."
                ]
            )
        }

        if let existingURL = LocalEbookImporter.shared.resolveEbookForOverlay(book: book),
            FileManager.default.fileExists(atPath: existingURL.path)
        {
            await persistStorytellerReadaloudBook(
                book,
                offlineURL: existingURL,
                prepareAudio: prepareForOfflinePlayback
            )
            return existingURL
        }

        let provider = suppliedProvider ?? (providerConnections.provider(for: book) as? StorytellerProvider)
        guard let provider else {
            throw DownloadError.missingCredentials("No active Storyteller connection found")
        }

        let cacheTask: Task<URL, Error>
        let cacheTaskId: UUID
        if let inFlight = storytellerReadaloudCacheTasks[book.uniqueId] {
            cacheTask = inFlight.task
            cacheTaskId = inFlight.id
        } else {
            cacheTaskId = UUID()
            cacheTask = Task {

                let cachedURL = try await provider.downloadReadaloud(for: book, onProgress: onProgress)
                try Task.checkCancellation()
                try Self.validateDownloadedEbook(cachedURL)
                return cachedURL
            }
            storytellerReadaloudCacheTasks[book.uniqueId] = (cacheTaskId, cacheTask)
        }
        let offlineURL: URL
        do {
            offlineURL = try await cacheTask.value
            if storytellerReadaloudCacheTasks[book.uniqueId]?.id == cacheTaskId {
                storytellerReadaloudCacheTasks[book.uniqueId] = nil
            }
        } catch {
            if storytellerReadaloudCacheTasks[book.uniqueId]?.id == cacheTaskId {
                storytellerReadaloudCacheTasks[book.uniqueId] = nil
            }
            throw error
        }
        await persistStorytellerReadaloudBook(
            book,
            offlineURL: offlineURL,
            prepareAudio: prepareForOfflinePlayback
        )
        return offlineURL
    }

    func pause(taskId: String) {
        guard let task = tasks.first(where: { $0.id == taskId }),
            task.status == .downloading
        else { return }

        let bookId = task.bookId
        if let urlTask = activeURLTasks[bookId] {
            urlTask.cancel { [weak self] resumeDataResult in
                Task { @MainActor [weak self] in
                    if let data = resumeDataResult {
                        self?.resumeData[bookId] = data
                    }
                    self?.updateTask(taskId) { $0.status = .paused }
                    self?.activeURLTasks.removeValue(forKey: bookId)
                    AppLogger.network.debug("Paused download diagnosticID=\(self?.diagnosticID(bookId) ?? "unknown")")
                }
            }
        } else {
            updateTask(taskId) { $0.status = .paused }
        }
    }

    func resume(taskId: String, book: Book) async {
        guard let task = tasks.first(where: { $0.id == taskId }),
            task.status == .paused
        else { return }

        if let reason = downloadBlockedReason {
            lastError = reason
            return
        }

        resumeData.removeValue(forKey: task.bookId)
        updateTask(taskId) { $0.status = .queued }

        var mutableTask = task
        await startDownload(task: &mutableTask, book: book)
    }

    func cancel(taskId: String) {
        guard let task = tasks.first(where: { $0.id == taskId }) else { return }

        if let urlTask = activeURLTasks[task.bookId] {
            urlTask.cancel()
            activeURLTasks.removeValue(forKey: task.bookId)
        }

        BookDownloadManager.shared.cancelDownload(bookId: task.bookId)

        resumeData.removeValue(forKey: task.bookId)

        updateTask(taskId) { $0.status = .cancelled }

        AppLogger.network.debug("Cancelled download diagnosticID=\(diagnosticID(task.bookId))")
    }

    func remove(taskId: String) {
        cancel(taskId: taskId)
        tasks.removeAll { $0.id == taskId }
        saveQueue()
    }

    func clearCompleted() {
        tasks.removeAll { $0.status == .completed || $0.status == .cancelled }
        saveQueue()
    }

    func retry(taskId: String, book: Book) async {
        guard let task = tasks.first(where: { $0.id == taskId }),
            task.status == .failed
        else { return }

        resumeData.removeValue(forKey: task.bookId)

        updateTask(taskId) {
            $0.status = .queued
            $0.progress = 0
            $0.bytesDownloaded = 0
            $0.errorMessage = nil
        }

        var mutableTask = task
        await startDownload(task: &mutableTask, book: book)
    }

    func deleteDownload(book: Book) async {
        await deleteDownloads(bookIds: storageManager.ownedCandidateBookIds(for: book))
    }

    func deleteDownload(bookId: String) async {
        await deleteDownloads(bookIds: [bookId])
    }

    private func deleteDownloads(bookIds: [String]) async {
        let bookIds = Set(bookIds)
        let taskIds = tasks.filter { bookIds.contains($0.bookId) }.map(\.id)
        for taskId in taskIds {
            remove(taskId: taskId)
        }
        tasks.removeAll { bookIds.contains($0.bookId) }
        saveQueue()

        for session in [urlSession!, foregroundURLSession!] {
            let sessionTasks = await session.allTasks
            for sessionTask in sessionTasks {
                guard let description = sessionTask.taskDescription else { continue }
                let parts = description.split(separator: "|", maxSplits: 1)
                guard parts.count == 2, bookIds.contains(String(parts[1])) else { continue }
                sessionTask.cancel()
            }
        }

        for bookId in bookIds {
            activeURLTasks.removeValue(forKey: bookId)?.cancel()
            BookDownloadManager.shared.cancelDownload(bookId: bookId)
            BookDownloadManager.shared.clearState(bookId: bookId)
        }

        await Task.detached(priority: .utility) {
            for bookId in bookIds {
                _ = await LocalStorageManager.shared.deleteAudiobook(bookId)
            }
        }.value

        openBookIds.subtract(bookIds)
        NotificationCenter.default.post(name: .localLibraryUpdated, object: nil)
        NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
    }

    func downloadFileCopy(bookId: String, title: String, sourceURL: URL, securityScopedRootURL: URL? = nil) async {
        if storageManager.isAudiobookDownloaded(bookId) {
            return
        }

        tasks.removeAll { $0.bookId == bookId && ($0.status == .completed || $0.status == .failed || $0.status == .cancelled) }
        if tasks.contains(where: { $0.bookId == bookId && $0.isActive }) {
            return
        }

        let task = BookDownloadTask.create(bookId: bookId, title: title, source: .local)
        tasks.append(task)
        saveQueue()
        updateTask(task.id) { $0.status = .downloading }

        await BookDownloadManager.shared.startFileCopyDownload(
            bookId: bookId,
            sourceURL: sourceURL,
            securityScopedRootURL: securityScopedRootURL
        )
        await monitorExternalDownload(taskId: task.id, bookId: bookId)
    }

    func cleanupFailedDownloads() async {
        let prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
        guard prefs.autoDeleteFailedDownloads else { return }

        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        let oldFailedTasks = tasks.filter {
            $0.status == .failed && $0.updatedAt < cutoff
        }

        for task in oldFailedTasks {
            AppLogger.network.debug("Auto-cleaning failed download diagnosticID=\(diagnosticID(task.bookId))")
            remove(taskId: task.id)
        }
    }

    func checkStorageLimit() async {
        let prefs = LibraryDisplayPreferencesStore.shared.loadPreferences()
        guard prefs.storageLimitEnabled else { return }

        let limitBytes = Int64(prefs.storageLimitGB) * 1024 * 1024 * 1024

        await Task.detached {
            let currentUsage = await LocalStorageManager.shared.totalAudiobooksSize()

            if currentUsage > limitBytes {
                AppLogger.network.info(
                    "Storage limit exceeded: \(ByteCountFormatter.string(fromByteCount: currentUsage, countStyle: .file)) > \(ByteCountFormatter.string(fromByteCount: limitBytes, countStyle: .file))"
                )

                let allBooks = await LocalStorageManager.shared.getOldestDownloadedBookIds()
                var bytesToFre = currentUsage - limitBytes

                for (bookId, _) in allBooks {
                    if bytesToFre <= 0 { break }

                    let size = await LocalStorageManager.shared.sizeOfAudiobook(bookId)
                    if await LocalStorageManager.shared.deleteAudiobook(bookId) {
                        bytesToFre -= size
                        AppLogger.network.info(
                            "Storage limit auto-clean diagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookId)) bytes=\(size)"
                        )

                        await MainActor.run {
                            UnifiedDownloadService.shared.removeTaskForBook(bookId)
                        }
                    }
                }

                await MainActor.run {
                    NotificationCenter.default.post(name: .localLibraryUpdated, object: nil)
                }
            }
        }.value
    }

    private func removeTaskForBook(_ bookId: String) {
        if let task = tasks.first(where: { $0.bookId == bookId }) {
            remove(taskId: task.id)
        }
    }

    private var openBookIds: Set<String> = []

    func registerOpenBook(_ bookId: String) {
        openBookIds.insert(bookId)
    }

    func unregisterOpenBook(_ bookId: String) {
        openBookIds.remove(bookId)
    }

    private func startDownload(task: inout BookDownloadTask, book: Book) async {
        updateTask(task.id) { $0.status = .downloading }

        do {
            let plan = try DownloadPlanRegistry.shared.plan(for: book)
            try await plan.execute(using: self, task: task, book: book)

            await cacheAssetsForOffline(book: book)

        } catch is CancellationError {
            updateTask(task.id) {
                $0.status = .cancelled
                $0.errorMessage = nil
            }
            AppLogger.network.debug("Download cancelled diagnosticID=\(diagnosticID(book.stableId))")
        } catch {
            if Task.isCancelled || Self.isCancellationError(error) {
                updateTask(task.id) {
                    $0.status = .cancelled
                    $0.errorMessage = nil
                }
                AppLogger.network.debug("Download cancelled diagnosticID=\(diagnosticID(book.stableId))")
                return
            }
            updateTask(task.id) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
            }
            lastError = error.localizedDescription
            NotificationCenter.default.post(name: Self.downloadFailedNotification, object: task.bookId)
            AppLogger.network.error("Download failed: \(error.localizedDescription)")
            let errorMessage = error.localizedDescription
            let bookTitle = book.title
            await MainActor.run {
                presentation.presentError(
                    title: "Download Failed",
                    message: "\(bookTitle): \(errorMessage)"
                )
            }
        }
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (error as? URLError)?.code == .cancelled
    }

    func downloadFromLocalOrPodcast(task: BookDownloadTask, book: Book) async throws {
        if book.isPodcastEpisode, let remoteURL = resolveRemotePodcastURL(for: book) {
            try await downloadFromRemotePodcastURL(task: task, book: book, remoteURL: remoteURL)
        } else {
            try await downloadFromLocal(task: task, book: book)
        }
    }

    private static func validateDownloadedEbook(_ url: URL) throws {
        guard EbookFormat.from(fileExtension: url.pathExtension) != nil else {
            throw NSError(
                domain: "UnifiedDownloadService",
                code: -4,
                userInfo: [
                    NSLocalizedDescriptionKey: "The server did not return a supported ebook file."
                ]
            )
        }
        if url.pathExtension.caseInsensitiveCompare(EbookFormat.epub.rawValue) == .orderedSame,
            !isStructurallyValidZip(url)
        {
            try? FileManager.default.removeItem(at: url)
            throw NSError(
                domain: "UnifiedDownloadService",
                code: -5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The downloaded EPUB is incomplete or damaged. Check the server and try again."
                ]
            )
        }
    }

    private static func isStructurallyValidZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let length = try? handle.seekToEnd(), length >= 22 else { return false }
        try? handle.seek(toOffset: 0)
        guard let header = try? handle.read(upToCount: 2), header == Data([0x50, 0x4B]) else {
            return false
        }
        let tailLength = min(length, 65_557)
        try? handle.seek(toOffset: length - tailLength)
        guard let tail = try? handle.read(upToCount: Int(tailLength)), tail.count == Int(tailLength) else {
            return false
        }
        var index = tail.count - 4
        while index >= 0 {
            if tail[index] == 0x50, tail[index + 1] == 0x4B, tail[index + 2] == 0x05, tail[index + 3] == 0x06 {
                return true
            }
            index -= 1
        }
        return false
    }

    func downloadFromAudiobookshelf(task: BookDownloadTask, book: Book) async throws {
        let backend = await resolveAudiobookshelfBackend(for: book)

        guard let backend = backend, let token = backend.token, !token.isEmpty else {
            AppLogger.network.error("[ABS Download] Failed to find backend for book:")
            AppLogger.network.info("bookDiagnosticID=\(diagnosticID(book.stableId)) hasBackendId=\(book.backendId != nil)")
            AppLogger.network.info("book.source: \(book.source)")
            throw DownloadError.missingCredentials("Audiobookshelf not configured. Please ensure your server is connected.")
        }

        AppLogger.network.debug("[ABS Download] Resolved backend")

        let baseUrl = backend.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let itemId = book.partKey ?? book.id

        let audioFileInos = book.audioFileInos ?? (book.audioFileIno.map { [$0] } ?? [])

        if audioFileInos.isEmpty {
            AppLogger.network.info("[ABS Download] No audioFileIno stored, fetching library item details...")
            try await downloadFromAudiobookshelfWithFetch(task: task, book: book, backend: backend)
            return
        }

        if audioFileInos.count == 1, let ino = audioFileInos.first {
            guard let url = URL(string: "\(baseUrl)/api/items/\(itemId)/file/\(ino)/download?token=\(token)") else {
                throw DownloadError.invalidURL
            }

            AppLogger.network.info("[ABS Download] Single file URL: \(url.redacted)")

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            await startURLSessionDownload(taskId: task.id, bookId: task.bookId, request: request)
        } else {
            AppLogger.network.info("[ABS Download] Multi-file book with \(audioFileInos.count) files")
            try await downloadMultipleAudiobookshelfFiles(task: task, book: book, backend: backend, audioFileInos: audioFileInos)
        }
    }

    private func downloadFromAudiobookshelfWithFetch(task: BookDownloadTask, book: Book, backend: BackendConfig) async throws {
        let itemId = book.partKey ?? book.id

        do {
            let item = try await AudiobookshelfService.shared.getLibraryItem(id: itemId, backend: backend, expanded: true)

            guard let audioFiles = item.media?.audioFiles, !audioFiles.isEmpty else {
                throw DownloadError.fileNotFound
            }

            let audioFileInos = audioFiles.compactMap { $0.ino }
            guard !audioFileInos.isEmpty else {
                throw DownloadError.fileNotFound
            }

            if audioFileInos.count == 1, let ino = audioFileInos.first {
                let baseUrl = backend.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard let token = backend.token,
                    let url = URL(string: "\(baseUrl)/api/items/\(itemId)/file/\(ino)/download?token=\(token)")
                else {
                    throw DownloadError.invalidURL
                }

                var request = URLRequest(url: url)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                await startURLSessionDownload(taskId: task.id, bookId: task.bookId, request: request)
            } else {
                try await downloadMultipleAudiobookshelfFiles(
                    task: task,
                    book: book,
                    backend: backend,
                    audioFileInos: audioFileInos,
                    audioFiles: audioFiles
                )
            }
        } catch {
            AppLogger.network.error("[ABS Download] Failed to fetch library item: \(error)")
            throw error
        }
    }

    private func downloadMultipleAudiobookshelfFiles(
        task: BookDownloadTask,
        book: Book,
        backend: BackendConfig,
        audioFileInos: [String],
        audioFiles: [ABSAudioFile]? = nil
    ) async throws {
        let baseUrl = backend.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let itemId = book.partKey ?? book.id
        guard let token = backend.token else {
            throw DownloadError.missingCredentials("No token available")
        }

        let totalFiles = audioFileInos.count
        var completedFiles = 0

        let destinationDir = try destinations.prepareBookDirectory(for: task.bookId)

        for (index, ino) in audioFileInos.enumerated() {
            guard let url = URL(string: "\(baseUrl)/api/items/\(itemId)/file/\(ino)/download?token=\(token)") else {
                continue
            }

            AppLogger.network.info("[ABS Download] Downloading file \(index + 1)/\(totalFiles)")

            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (tempURL, response) = try await URLSession.shared.download(for: request)

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw DownloadError.missingCredentials("Server returned error")
            }

            let fileExtension: String
            if let files = audioFiles, index < files.count, let ext = files[index].metadata?.ext, !ext.isEmpty {
                fileExtension = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
            } else if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") {
                switch contentType.lowercased() {
                case let ct where ct.contains("mpeg"): fileExtension = "mp3"
                case let ct where ct.contains("mp4"), let ct where ct.contains("m4a"), let ct where ct.contains("m4b"):
                    fileExtension = "m4b"
                case let ct where ct.contains("flac"): fileExtension = "flac"
                case let ct where ct.contains("ogg"): fileExtension = "ogg"
                default: fileExtension = "m4b"
                }
            } else {
                fileExtension = "m4b"
            }

            let destURL = DownloadDestinationFileSystem.chapterFile(
                in: destinationDir,
                index: index,
                fileExtension: fileExtension
            )
            try DownloadDestinationFileSystem.replaceItem(at: destURL, with: tempURL)

            completedFiles += 1
            let progress = Double(completedFiles) / Double(totalFiles)

            updateTask(task.id) {
                $0.progress = progress
                $0.bytesDownloaded = Int64(Double(completedFiles))
                $0.totalBytes = Int64(totalFiles)
            }
        }

        updateTask(task.id) {
            $0.status = .completed
            $0.progress = 1.0
        }
        BookDownloadManager.shared.markAsCompleted(bookId: task.bookId)
        NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: task.bookId)
        AppLogger.network.info("[ABS Download] Multi-file download completed: \(totalFiles) files")
    }

    private func resolveAudiobookshelfBackend(for book: Book) async -> BackendConfig? {
        let enabled = providerConnections.allBackends()
            .filter { $0.type == .audiobookshelf && $0.enabled }

        AppLogger.network.info("[ABS Backend] Looking for backend, found \(enabled.count) enabled ABS backends")
        AppLogger.network.info(
            "[ABS Backend] bookDiagnosticID=\(diagnosticID(book.stableId)) hasBackendId=\(book.backendId != nil) hasLibraryId=\(!book.libraryId.isEmpty)"
        )

        if let backendId = book.backendId, !backendId.isEmpty {
            AppLogger.network.debug("[ABS Backend] Book has backend identifier")
            if let match = enabled.first(where: { $0.id.lowercased() == backendId.lowercased() }) {
                AppLogger.network.info("[ABS Backend] Matched by backendId")
                return match
            }

            if let match = providerConnections.backend(id: backendId) {
                AppLogger.network.info("[ABS Backend] Matched via AppState.findBackend")
                return match
            }
        }

        let libraryId = book.libraryId.isEmpty ? nil : book.libraryId
        if let libraryId = libraryId {
            AppLogger.network.debug("[ABS Backend] Trying selected library match")

            for backend in enabled {
                let selectedLibs = backend.selectedLibraryIds ?? []
                if selectedLibs.contains(libraryId) {
                    AppLogger.network.debug("[ABS Backend] Matched by selected libraries")
                    return backend
                }
            }

            if let libraryName = book.libraryName {
                let components = libraryName.split(separator: "_")
                if components.count >= 2, let potentialBackendId = components.first {
                    let backendIdStr = String(potentialBackendId)
                    if let match = enabled.first(where: { $0.id.lowercased() == backendIdStr.lowercased() }) {
                        AppLogger.network.info("[ABS Backend] Matched by libraryName pattern")
                        return match
                    }
                }
            }

            let components = libraryId.split(separator: "_")
            if components.count >= 2, let potentialBackendId = components.first {
                let backendIdStr = String(potentialBackendId)
                if let match = enabled.first(where: { $0.id.lowercased() == backendIdStr.lowercased() }) {
                    AppLogger.network.info("[ABS Backend] Matched by libraryId pattern")
                    return match
                }
            }
        }

        if enabled.count == 1 {
            AppLogger.network.debug("[ABS Backend] Using only available backend")
            return enabled.first
        }

        if enabled.count > 1 {
            let itemId = book.partKey ?? book.id
            AppLogger.network.debug("[ABS Backend] Probing backends for bookDiagnosticID=\(diagnosticID(book.stableId))")

            for backend in enabled {
                do {
                    let _ = try await AudiobookshelfService.shared.getLibraryItem(id: itemId, backend: backend)
                    AppLogger.network.debug("[ABS Backend] Found item")
                    return backend
                } catch {
                    AppLogger.network.debug("[ABS Backend] Item probe failed: \(error.localizedDescription)")
                    continue
                }
            }

            AppLogger.network.warning("[ABS Backend] Query failed for all backends; using first available")
            return enabled.first
        }

        if let creds = try? SecureTokenStorage.shared.loadCredentials(forService: "audiobookshelf") {
            AppLogger.network.info("[ABS Backend] Found legacy credentials")
            return BackendConfig(
                id: "audiobookshelf_legacy",
                name: "Audiobookshelf",
                type: .audiobookshelf,
                url: creds.serverUrl,
                token: creds.token,
                enabled: true,
                username: creds.username,
                password: nil,
                userId: nil,
                selectedLibraryIds: nil
            )
        }

        if let first = enabled.first {
            AppLogger.network.debug("[ABS Backend] Using first available backend")
            return first
        }

        AppLogger.network.info("[ABS Backend] No backend found")
        return nil
    }

    func downloadFromRealDebrid(task: BookDownloadTask, book: Book) async throws {
        let tracks = book.audioTracks ?? []
        guard let first = tracks.first, let contentUrl = first.contentUrl, let url = URL(string: contentUrl) else {
            throw DownloadError.invalidURL
        }
        let relatedArchiveBooks = await realDebridArchiveBooks(for: book, archiveURL: contentUrl)

        let uniqueURLs = Set(tracks.compactMap(\.contentUrl))
        let isArchiveBundle = uniqueURLs.count == 1 && tracks.count > 1

        if isArchiveBundle || tracks.count <= 1 {
            try await rawHTTP11Download(
                taskId: task.id,
                bookId: task.bookId,
                url: url,
                headers: [:],
                realDebridArchiveBooks: relatedArchiveBooks
            )
        } else {
            try await downloadMultipleRemoteFiles(task: task, tracks: tracks, headers: [:])
        }
    }

    func rawHTTP11Download(
        taskId: String,
        bookId: String,
        url: URL,
        headers: [String: String],
        realDebridArchiveBooks: [Book]? = nil
    ) async throws {
        let destinationDir = try destinations.prepareBookDirectory(for: bookId)

        let ext = url.pathExtension.isEmpty ? "m4b" : url.pathExtension.lowercased()
        let finalURL = DownloadDestinationFileSystem.chapterFile(in: destinationDir, index: 0, fileExtension: ext)
        let tempURL = finalURL.appendingPathExtension("tmp")

        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: finalURL)

        AppLogger.network.debug("Started raw HTTP download diagnosticID=\(diagnosticID(bookId))")

        let downloader = HTTP11FileDownloader(url: url, headers: headers, tempFileURL: tempURL)
        downloader.start()

        while true {
            try await Task.sleep(nanoseconds: 500_000_000)

            if let dlError = downloader.error {
                downloader.cancel()
                try? FileManager.default.removeItem(at: tempURL)
                throw dlError
            }

            let written = downloader.bytesWritten
            let expected = downloader.expectedLength

            let progress = expected > 0 ? Double(written) / Double(expected) : 0
            let total = expected > 0 ? expected : written

            await MainActor.run { [weak self] in
                self?.updateTask(taskId, persist: false) {
                    $0.progress = progress
                    $0.bytesDownloaded = written
                    $0.totalBytes = total
                }
            }

            if downloader.isComplete {
                break
            }
        }

        if let dlError = downloader.error {
            try? FileManager.default.removeItem(at: tempURL)
            throw dlError
        }

        downloader.closeFile()

        let bytesWritten = downloader.bytesWritten
        guard bytesWritten > 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw DownloadError.missingCredentials("Downloaded 0 bytes")
        }

        try DownloadDestinationFileSystem.replaceItem(at: finalURL, with: tempURL)

        AppLogger.network.debug("HTTP download completed diagnosticID=\(diagnosticID(bookId)) bytes=\(bytesWritten)")

        if ext == "zip" || DownloadArchiveFileSystem.isZipFile(at: finalURL) {
            try DownloadArchiveFileSystem.extractZip(at: finalURL, to: destinationDir)
        } else if ext == "rar" || DownloadArchiveFileSystem.isRarFile(at: finalURL) {
            AppLogger.network.debug("RAR archive detected diagnosticID=\(diagnosticID(bookId)); extracting")
            if let realDebridArchiveBooks, !realDebridArchiveBooks.isEmpty {
                // Keep the archive outside book directories while distribution clears each destination.
                let staged = try DownloadArchiveFileSystem.stageForDistribution(at: finalURL)
                defer { staged.discard() }
                await distributeRealDebridArchive(from: staged.url, books: realDebridArchiveBooks)
            } else {
                let extracted = try DownloadArchiveFileSystem.extractRar(at: finalURL, to: destinationDir)
                AppLogger.network.debug("Extracted RAR audio files count=\(extracted.count)")
            }
        }

        await MainActor.run { [weak self] in
            self?.updateTask(taskId) {
                $0.status = .completed
                $0.progress = 1.0
            }
            self?.activeURLTasks.removeValue(forKey: bookId)
            self?.expectedBytesByTaskId.removeValue(forKey: taskId)
            BookDownloadManager.shared.markAsCompleted(bookId: bookId)
            NotificationCenter.default.post(name: UnifiedDownloadService.downloadCompletedNotification, object: bookId)
        }
    }

    private func distributeRealDebridArchive(from rarURL: URL, books: [Book]) async {
        let uniqueBooks = Dictionary(grouping: books, by: \.downloadKey).compactMap { $0.value.first }

        for bundleBook in uniqueBooks {
            let destinationDir = destinations.bookDirectory(for: bundleBook.downloadKey)
            let selection = realDebridArchiveSelection(for: bundleBook)

            do {
                try destinations.removeBookDirectory(for: bundleBook.downloadKey)

                let extracted = try RARExtractor.extractAudioFiles(
                    from: rarURL,
                    to: destinationDir,
                    selection: selection,
                    removeArchiveAfterExtraction: false
                )

                guard !extracted.isEmpty else { continue }

                AppLogger.network.debug("Routed \(extracted.count) extracted files diagnosticID=\(diagnosticID(bundleBook.stableId))")
                BookDownloadManager.shared.markAsCompleted(bookId: bundleBook.downloadKey)
                NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: bundleBook.downloadKey)
                await refreshOfflineMetadataFromDownloadedFiles(book: bundleBook, bookId: bundleBook.downloadKey)
            } catch {
                AppLogger.network.error("Failed to route Real-Debrid archive diagnosticID=\(diagnosticID(bundleBook.stableId)): \(error.localizedDescription)")
            }
        }
    }

    private func realDebridArchiveBooks(for book: Book, archiveURL: String) async -> [Book] {
        guard book.source == .realdebrid else { return [book] }

        let allBooks = await bookQuerying.allBooks()
        let matched = allBooks.filter { candidate in
            guard candidate.source == .realdebrid else { return false }
            guard candidate.providerId == book.providerId else { return false }
            guard candidate.libraryId == book.libraryId else { return false }
            return (candidate.audioTracks ?? []).contains { $0.contentUrl == archiveURL }
        }

        if matched.isEmpty {
            return [book]
        }

        if matched.contains(where: { $0.downloadKey == book.downloadKey }) {
            return matched
        }

        return matched + [book]
    }

    private func realDebridArchiveSelection(for book: Book) -> RARExtractor.ExtractionSelection? {
        guard book.source == .realdebrid else { return nil }

        let normalizedTrackPaths = Set(
            (book.audioTracks ?? []).compactMap { track in
                normalizeArchivePath(track.filePath)
            }
        )

        let trackFolderNames = Set(
            (book.audioTracks ?? []).compactMap { track in
                archiveFolderName(from: track.filePath)
            }
        )

        let fallbackFolderNames = Set(
            [
                archiveFolderName(from: book.filePath),
                normalizeArchiveComponent(book.filePath),
                normalizeArchiveComponent(book.title),
            ].compactMap { $0 }
        )

        let fileBaseNames = Set(
            (book.audioTracks ?? []).compactMap { track in
                guard let filePath = track.filePath else { return nil }
                let normalized = normalizeArchivePath(Optional(filePath)) ?? ""
                guard !normalized.isEmpty else { return nil }
                let lastPathComponent = (normalized as NSString).lastPathComponent
                return (lastPathComponent as NSString).deletingPathExtension.lowercased()
            } + [normalizeArchiveComponent(book.title)].compactMap { $0 }
        )

        let selection = RARExtractor.ExtractionSelection(
            filePaths: normalizedTrackPaths,
            folderNames: trackFolderNames.union(fallbackFolderNames),
            fileBaseNames: fileBaseNames
        )

        return selection.isEmpty ? nil : selection
    }

    private func normalizeArchivePath(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized =
            value
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func archiveFolderName(from value: String?) -> String? {
        guard let normalized = normalizeArchivePath(value) else { return nil }
        let directory = (normalized as NSString).deletingLastPathComponent
        guard !directory.isEmpty, directory != "." else {
            if normalized.contains("/") {
                return (normalized as NSString).lastPathComponent.lowercased()
            }
            return nil
        }
        return (directory as NSString).lastPathComponent.lowercased()
    }

    private func normalizeArchiveComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }

    private func probeExpectedContentLength(url: URL, headers: [String: String]) async -> Int64? {
        let probeSession = URLSession(configuration: .ephemeral)
        defer { probeSession.invalidateAndCancel() }

        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 30
        headers.forEach { headRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        headRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        headRequest.setValue("Enve/1.0", forHTTPHeaderField: "User-Agent")

        if let (_, response) = try? await probeSession.data(for: headRequest),
            let http = response as? HTTPURLResponse,
            (200...299).contains(http.statusCode),
            let contentLength = http.value(forHTTPHeaderField: "Content-Length"),
            let value = Int64(contentLength),
            value > 0
        {
            return value
        }

        var rangeRequest = URLRequest(url: url)
        rangeRequest.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        rangeRequest.timeoutInterval = 30
        headers.forEach { rangeRequest.setValue($0.value, forHTTPHeaderField: $0.key) }
        rangeRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        rangeRequest.setValue("Enve/1.0", forHTTPHeaderField: "User-Agent")

        if let (_, response) = try? await probeSession.data(for: rangeRequest),
            let http = response as? HTTPURLResponse,
            let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        {
            if let totalPart = contentRange.split(separator: "/").last,
                let total = Int64(totalPart), total > 0
            {
                return total
            }
        }

        return nil
    }

    func downloadMultipleRemoteFiles(task: BookDownloadTask, tracks: [AudioTrack], headers: [String: String]) async throws {
        let totalFiles = tracks.count
        var completedFiles = 0

        let destinationDir = try destinations.prepareBookDirectory(for: task.bookId)

        for (index, track) in tracks.enumerated() {
            guard let contentUrl = track.contentUrl, let url = URL(string: contentUrl) else { continue }

            var request = URLRequest(url: url)
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            request.setValue("Enve/1.0", forHTTPHeaderField: "User-Agent")

            guard let session = foregroundURLSession else {
                throw DownloadError.missingCredentials("Download session not available")
            }
            let (tempURL, response) = try await session.download(for: request)

            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw DownloadError.missingCredentials("Server returned error")
            }

            let ext = url.pathExtension.isEmpty ? "m4b" : url.pathExtension
            let destURL = DownloadDestinationFileSystem.chapterFile(in: destinationDir, index: index, fileExtension: ext)
            try DownloadDestinationFileSystem.replaceItem(at: destURL, with: tempURL)

            completedFiles += 1
            let progress = Double(completedFiles) / Double(totalFiles)

            updateTask(task.id) {
                $0.progress = progress
                $0.bytesDownloaded = Int64(Double(completedFiles))
                $0.totalBytes = Int64(totalFiles)
            }
        }

        updateTask(task.id) {
            $0.status = .completed
            $0.progress = 1.0
        }
        BookDownloadManager.shared.markAsCompleted(bookId: task.bookId)
        NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: task.bookId)
        AppLogger.network.info("[WebDAV Download] Multi-file download completed: \(totalFiles) files")
    }

    func downloadFromSMB(task: BookDownloadTask, book: Book) async throws {
        guard let sourceId = book.backendId else {
            throw DownloadError.missingCredentials("SMB source not found")
        }

        let sources = await SMBLibraryService.shared.getSources()
        guard let source = sources.first(where: { $0.id == sourceId }) else {
            throw DownloadError.missingCredentials("SMB source not configured")
        }

        guard let password = await SMBLibraryService.shared.getPassword(for: sourceId) else {
            throw DownloadError.missingCredentials("SMB password not found")
        }

        let smbBooks = await SMBLibraryService.shared.getBooks(for: sourceId)
        guard let smbBook = smbBooks.first(where: { $0.id == book.id }) else {
            throw DownloadError.fileNotFound
        }

        let taskId = task.id
        let bookId = task.bookId

        await MainActor.run {
            BookDownloadManager.shared.clearCompletedState(bookId: bookId)
        }

        AppLogger.network.debug("[SMB Download] Starting diagnosticID=\(diagnosticID(book.stableId))")

        let monitorTask = Task {
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                let isCompleted = await MainActor.run {
                    BookDownloadManager.shared.completedBookIds.contains(bookId)
                }
                if isCompleted {
                    self.updateTask(taskId) {
                        $0.status = .completed
                        $0.progress = 1.0
                    }
                    AppLogger.network.debug("[SMB Download] Completed diagnosticID=\(diagnosticID(bookId))")
                    NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: bookId)
                    return
                }

                let isActive = await MainActor.run {
                    BookDownloadManager.shared.activeBookIds.contains(bookId)
                }
                if !isActive {
                    if let error = await MainActor.run(body: { BookDownloadManager.shared.lastErrorByBookId[bookId] }) {
                        AppLogger.network.error("[SMB Download] Failed diagnosticID=\(diagnosticID(bookId)): \(error)")
                        self.updateTask(taskId) {
                            $0.status = .failed
                            $0.errorMessage = error
                        }
                        return
                    }

                    let finalCheck = await MainActor.run {
                        BookDownloadManager.shared.completedBookIds.contains(bookId)
                    }
                    if finalCheck {
                        self.updateTask(taskId) {
                            $0.status = .completed
                            $0.progress = 1.0
                        }
                        AppLogger.network.debug("[SMB Download] Completed on final check diagnosticID=\(diagnosticID(bookId))")
                        NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: bookId)
                        return
                    }

                    AppLogger.network.error("[SMB Download] Stopped unexpectedly diagnosticID=\(diagnosticID(bookId))")
                    return
                }

                let progress = await MainActor.run {
                    BookDownloadManager.shared.progressByBookId[bookId] ?? 0
                }
                if self.shouldEmitProgressUpdate(taskId: taskId, progress: progress) {
                    self.updateTask(taskId, persist: false) { $0.progress = progress }
                }
            }
        }

        await BookDownloadManager.shared.startSMBDownload(
            bookId: bookId,
            smbBook: smbBook,
            source: source,
            password: password
        )

        await monitorTask.value
    }

    func downloadEbookViaProvider(task: BookDownloadTask, book: Book) async throws {
        guard let provider = providerConnections.capability(EbookDownloadProvider.self, for: book) else {
            throw DownloadError.missingCredentials("No active connection found for this server")
        }

        let taskId = task.id
        let downloadedURL = try await provider.downloadEbook(
            for: book,
            onProgress: { [weak self] progress in
                DispatchQueue.main.async { [weak self] in
                    self?.updateTask(taskId, persist: false) {
                        $0.progress = progress
                    }
                }
            }
        )
        try Task.checkCancellation()
        try Self.validateDownloadedEbook(downloadedURL)

        let offlineURL = try LocalEbookImporter.shared.persistRemoteEbookForOffline(
            from: downloadedURL,
            preferredFilename: downloadedURL.lastPathComponent,
            bookIdentifier: book.id
        )
        try Task.checkCancellation()

        libraryCache.mutateBook(uniqueId: book.uniqueId) { $0.ebookFileURL = offlineURL }
        await bookWriting.updateEbookFileURL(
            uniqueId: book.uniqueId,
            url: offlineURL
        )

        updateTask(task.id) {
            $0.status = .completed
            $0.progress = 1.0
        }
        NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: task.bookId)
        AppLogger.network.debug("Ebook downloaded diagnosticID=\(diagnosticID(book.stableId))")
    }

    func downloadAudiobookFromStoryteller(task: BookDownloadTask, book: Book) async throws {
        guard let provider = providerConnections.provider(for: book) as? StorytellerProvider else {
            throw DownloadError.missingCredentials("No active Storyteller connection found")
        }

        if book.epub3Features?.hasMediaOverlay == true {
            try await downloadStorytellerReadaloud(task: task, book: book, provider: provider)
            return
        }

        let request = try provider.audiobookDownloadRequest(for: book)

        AppLogger.network.debug("[Storyteller Download] Starting audiobook diagnosticID=\(diagnosticID(book.stableId))")
        await startURLSessionDownload(taskId: task.id, bookId: task.bookId, request: request)
    }

    private func downloadStorytellerReadaloud(task: BookDownloadTask, book: Book, provider: StorytellerProvider) async throws {
        let taskId = task.id
        AppLogger.network.debug("[Storyteller Download] Starting read-aloud diagnosticID=\(diagnosticID(book.stableId))")

        let offlineURL = try await ensureStorytellerReadaloudCached(
            for: book,
            provider: provider,
            onProgress: { [weak self] progress in
                DispatchQueue.main.async { [weak self] in
                    self?.updateTask(taskId, persist: false) { $0.progress = progress }
                }
            },
            prepareForOfflinePlayback: true
        )

        updateTask(task.id) {
            $0.status = .completed
            $0.progress = 1.0
        }
        BookDownloadManager.shared.markAsCompleted(bookId: task.bookId)
        NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: task.bookId)
        #if !os(tvOS)
        AppLogger.network.debug("Read-aloud EPUB downloaded diagnosticID=\(diagnosticID(book.stableId)) extension=\(offlineURL.pathExtension)")
        #else
        AppLogger.network.debug("Read-aloud EPUB downloaded diagnosticID=\(diagnosticID(book.stableId))")
        #endif
    }

    private func persistStorytellerReadaloudBook(
        _ book: Book,
        offlineURL: URL,
        prepareAudio: Bool
    ) async {
        libraryCache.mutateBook(uniqueId: book.uniqueId) { $0.ebookFileURL = offlineURL }
        var updatedBook = libraryCache.bookInMemory(uniqueId: book.uniqueId) ?? book
        updatedBook.ebookFileURL = offlineURL

        #if !os(tvOS)
        let needsPrep = storytellerReadaloudNeedsPrep(book: updatedBook)
        if prepareAudio && needsPrep {
            let prep = await StorytellerReadaloudOfflinePrep.prepare(epubURL: offlineURL, book: updatedBook)
            if !prep.chapters.isEmpty {
                updatedBook.chapters = prep.chapters
                libraryCache.mutateBook(uniqueId: book.uniqueId) { $0.chapters = prep.chapters }
                ActivePlayback.composition.bookMetadataUpdater.updateChapters(prep.chapters, for: book)
            }
            AppLogger.network.info(
                "Prepared read-aloud EPUB diagnosticID=\(diagnosticID(book.stableId)) audioFiles=\(prep.extractedAudioCount) chapters=\(prep.chapters.count)"
            )
        }
        #endif

        await bookWriting.upsertBooks([updatedBook])
    }

    #if !os(tvOS)
    private func storytellerReadaloudNeedsPrep(book: Book) -> Bool {
        let hasChapters =
            book.chapters?.isEmpty == false
            || ReaderArtifactsStore.shared.loadCachedChapters(bookId: book.stableId)?.isEmpty == false
            || ReaderArtifactsStore.shared.loadCachedChapters(bookId: book.id)?.isEmpty == false

        let audioDir = LocalStorageManager.shared.bookAudioDirectory(for: book.downloadKey)
        let extractedAudioExists =
            ((try? FileManager.default.contentsOfDirectory(
                at: audioDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []).contains {
                AudiobookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil
            }

        return !hasChapters || !extractedAudioExists
    }
    #endif

    func downloadAudiobookViaProvider(task: BookDownloadTask, book: Book) async throws {
        guard let provider = providerConnections.capability(PlaybackSessionProvider.self, for: book) else {
            throw DownloadError.missingCredentials("No active connection found")
        }

        let downloadKey = book.downloadKey
        let headers = provider.getStreamingHeaders()

        var requests: [(request: URLRequest, mimeType: String?)] = []
        if let session = try? await provider.startPlaybackSession(for: book), !session.audioTracks.isEmpty {
            requests = session.audioTracks.compactMap { track in
                guard let url = URL(string: track.contentUrl) else { return nil }
                var req = URLRequest(url: url)
                for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                return (request: req, mimeType: track.mimeType)
            }
        }
        if requests.isEmpty, let url = provider.getAudioURL(for: book) {
            var req = URLRequest(url: url)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            requests = [(request: req, mimeType: nil)]
        }
        guard !requests.isEmpty else { throw DownloadError.invalidURL }

        if requests.count > 1 {
            await BookDownloadManager.shared.startMultiTrackHTTPDownload(bookId: downloadKey, requests: requests)
        } else {
            await BookDownloadManager.shared.startDownload(bookId: downloadKey, request: requests[0].request)
        }

        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 500_000_000)
            try Task.checkCancellation()

            let isComplete = await MainActor.run { BookDownloadManager.shared.completedBookIds.contains(downloadKey) }
            if isComplete {
                updateTask(task.id) {
                    $0.status = .completed
                    $0.progress = 1.0
                }
                NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: task.bookId)
                AppLogger.network.debug("Audiobook downloaded source=\(book.source.rawValue) diagnosticID=\(diagnosticID(book.stableId))")
                return
            }

            if let errorMsg = await MainActor.run(body: { BookDownloadManager.shared.lastErrorByBookId[downloadKey] }) {
                throw NSError(
                    domain: "UnifiedDownloadService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Audiobook download failed: \(errorMsg)"]
                )
            }
        }
    }

    func downloadAudiobookViaGrimmory(task: BookDownloadTask, book: Book) async throws {
        guard let provider = providerConnections.provider(for: book) as? BookloreProvider else {
            throw DownloadError.missingCredentials("No active Grimmory connection found")
        }

        _ = await provider.refreshStreamingTokenIfNeeded()

        let downloadKey = book.downloadKey

        func buildTrackRequests() async throws -> [(request: URLRequest, mimeType: String?)] {
            let headers = provider.getStreamingHeaders()
            if let trackInfos = await provider.fetchAudiobookDownloadTracks(for: book), trackInfos.count > 1 {
                AppLogger.network.info("[Grimmory] /info returned \(trackInfos.count) tracks for download")
                return trackInfos.compactMap { info in
                    var req = URLRequest(url: info.url)
                    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                    return (request: req, mimeType: info.mimeType)
                }
            }
            if let session = try? await provider.startPlaybackSession(for: book),
                session.audioTracks.count > 1
            {
                AppLogger.network.info("[Grimmory] session fallback returned \(session.audioTracks.count) tracks for download")
                return session.audioTracks.compactMap { track in
                    guard let url = URL(string: track.contentUrl) else { return nil }
                    var req = URLRequest(url: url)
                    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                    return (request: req, mimeType: track.mimeType)
                }
            }
            guard let url = provider.getAudioURL(for: book) else {
                throw DownloadError.invalidURL
            }
            var req = URLRequest(url: url)
            for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
            return [(request: req, mimeType: nil)]
        }

        func scheduleDownload(_ trackRequests: [(request: URLRequest, mimeType: String?)]) async {
            if trackRequests.count > 1 {
                await BookDownloadManager.shared.startMultiTrackHTTPDownload(bookId: downloadKey, requests: trackRequests)
            } else {
                await BookDownloadManager.shared.startDownload(bookId: downloadKey, request: trackRequests[0].request)
            }
        }

        let initialRequests = try await buildTrackRequests()
        guard !initialRequests.isEmpty else { throw DownloadError.invalidURL }
        await scheduleDownload(initialRequests)

        var didRetryOn401 = false

        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 500_000_000)
            try Task.checkCancellation()

            let isComplete = await MainActor.run { BookDownloadManager.shared.completedBookIds.contains(downloadKey) }
            if isComplete {
                updateTask(task.id) {
                    $0.status = .completed
                    $0.progress = 1.0
                }
                NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: task.bookId)
                AppLogger.network.debug("Grimmory audiobook downloaded diagnosticID=\(diagnosticID(book.stableId))")
                return
            }

            let hasError = await MainActor.run { BookDownloadManager.shared.lastErrorByBookId[downloadKey] }
            if let errorMsg = hasError {
                let isAuthFailure = errorMsg.contains("401") || errorMsg.lowercased().contains("unauthorized")
                if isAuthFailure && !didRetryOn401 {
                    didRetryOn401 = true
                    AppLogger.network.info("[Grimmory] download hit 401; refreshing JWT and retrying once")
                    let refreshed = await provider.refreshStreamingTokenIfNeeded(force: true)
                    if !refreshed {
                        throw NSError(
                            domain: "UnifiedDownloadService",
                            code: 401,
                            userInfo: [NSLocalizedDescriptionKey: "Grimmory download failed: 401 Unauthorized (token refresh failed)"]
                        )
                    }

                    BookDownloadManager.shared.cancelDownload(bookId: downloadKey)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    let retryRequests = try await buildTrackRequests()
                    guard !retryRequests.isEmpty else { throw DownloadError.invalidURL }
                    await scheduleDownload(retryRequests)
                    continue
                }
                throw NSError(
                    domain: "UnifiedDownloadService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Grimmory download failed: \(errorMsg)"]
                )
            }

            let cancelledExternally = await MainActor.run {
                tasks.first(where: { $0.id == task.id })?.status == .cancelled
            }
            if cancelledExternally {
                AppLogger.network.debug("Grimmory download cancelled diagnosticID=\(diagnosticID(book.stableId))")
                throw CancellationError()
            }

            let progress = await MainActor.run { BookDownloadManager.shared.progressByBookId[downloadKey] ?? 0 }
            updateTask(task.id, persist: false) {
                $0.progress = progress
            }
        }
    }

    private func downloadFromLocal(task: BookDownloadTask, book: Book) async throws {
        guard let libraryId = book.backendId else {
            throw DownloadError.missingCredentials("Local library not configured")
        }

        let rootURL: URL?
        if libraryId == LocalLibraryService.fileSharingLibraryId {
            rootURL = LocalLibraryService.fileSharingRootURL
        } else {
            guard let bookmarkData = LocalLibraryStorageStore.shared.loadBookmark(for: libraryId) else {
                throw DownloadError.missingCredentials("Local library not configured")
            }

            var isStale = false
            rootURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
        }

        let localBook = LocalLibraryStorageStore.shared.loadBooks(libraryId: libraryId).first(where: { $0.id == book.id })
        let sourceURL: URL

        if let relative = localBook?.relativePath, !relative.isEmpty,
            let rootURL
        {
            sourceURL = rootURL.appendingPathComponent(relative)
        } else if let filePath = localBook?.filePath {
            sourceURL = URL(fileURLWithPath: filePath)
        } else if let filePath = book.filePath {
            sourceURL = URL(fileURLWithPath: filePath)
        } else {
            throw DownloadError.fileNotFound
        }

        let taskId = task.id
        let bookId = task.bookId
        Task {
            await self.monitorExternalDownload(taskId: taskId, bookId: bookId)
        }

        await BookDownloadManager.shared.startFileCopyDownload(
            bookId: task.bookId,
            sourceURL: sourceURL,
            securityScopedRootURL: rootURL
        )
    }

    private func resolveRemotePodcastURL(for book: Book) -> URL? {
        if let partKey = book.partKey,
            let url = URL(string: partKey),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        {
            return url
        }

        if let filePath = book.filePath,
            let url = URL(string: filePath),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        {
            return url
        }

        return nil
    }

    private func downloadFromRemotePodcastURL(task: BookDownloadTask, book: Book, remoteURL: URL) async throws {
        var request = URLRequest(url: remoteURL)
        request.setValue("audio/*,application/octet-stream;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        await startURLSessionDownload(taskId: task.id, bookId: task.bookId, request: request)
    }

    func startURLSessionDownload(
        taskId: String,
        bookId: String,
        request: URLRequest,
        preferForegroundSession: Bool = false,
        expectedBytes: Int64? = nil
    ) async {
        let downloadTask: URLSessionDownloadTask
        guard let selectedSession = preferForegroundSession ? foregroundURLSession : urlSession else {
            AppLogger.network.info("No URL session available for download")
            return
        }
        if let data = resumeData[bookId] {
            downloadTask = selectedSession.downloadTask(withResumeData: data)
            resumeData.removeValue(forKey: bookId)
        } else {
            downloadTask = selectedSession.downloadTask(with: request)
        }

        if let expectedBytes, expectedBytes > 0 {
            expectedBytesByTaskId[taskId] = expectedBytes
        }

        activeURLTasks[bookId] = downloadTask
        downloadTask.taskDescription = "\(taskId)|\(bookId)"

        downloadTask.resume()

        AppLogger.network.debug("Started URLSession download diagnosticID=\(diagnosticID(bookId))")
    }

    private func monitorExternalDownload(taskId: String, bookId: String) async {
        let manager = BookDownloadManager.shared

        AppLogger.network.debug("Monitoring SMB download diagnosticID=\(diagnosticID(bookId))")

        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            let isCompleted = await MainActor.run { manager.completedBookIds.contains(bookId) }
            if isCompleted {
                AppLogger.network.debug("Download completed diagnosticID=\(diagnosticID(bookId))")
                updateTask(taskId) {
                    $0.status = .completed
                    $0.progress = 1.0
                }
                NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: bookId)
                return
            }

            let isActive = await MainActor.run { manager.activeBookIds.contains(bookId) }
            if !isActive {
                if let error = await MainActor.run(body: { manager.lastErrorByBookId[bookId] }) {
                    AppLogger.network.error("Download failed diagnosticID=\(diagnosticID(bookId)): \(error)")
                    updateTask(taskId) {
                        $0.status = .failed
                        $0.errorMessage = error
                    }
                    NotificationCenter.default.post(name: Self.downloadFailedNotification, object: bookId)
                    return
                }

                let isNowCompleted = await MainActor.run { manager.completedBookIds.contains(bookId) }
                if isNowCompleted {
                    AppLogger.network.debug("Download completed on late check diagnosticID=\(diagnosticID(bookId))")
                    updateTask(taskId) {
                        $0.status = .completed
                        $0.progress = 1.0
                    }
                    NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: bookId)
                    return
                }

                AppLogger.network.error("Download stopped unexpectedly diagnosticID=\(diagnosticID(bookId))")
                updateTask(taskId) {
                    $0.status = .failed
                    $0.errorMessage = "Download stopped unexpectedly"
                }
                return
            }

            let progress = await MainActor.run { manager.progressByBookId[bookId] ?? 0 }
            if shouldEmitProgressUpdate(taskId: taskId, progress: progress) {
                updateTask(taskId, persist: false) { $0.progress = progress }
            }
        }
    }

    enum DownloadError: LocalizedError {
        case missingCredentials(String)
        case invalidURL
        case fileNotFound
        case networkUnavailable
        case cancelled

        var errorDescription: String? {
            switch self {
            case .missingCredentials(let msg): return msg
            case .invalidURL: return "Invalid download URL"
            case .fileNotFound: return "Audio file not found"
            case .networkUnavailable: return "Network not available"
            case .cancelled: return "Download cancelled"
            }
        }
    }
}

extension UnifiedDownloadService: URLSessionDownloadDelegate {
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in
            #if os(iOS)
            guard let delegate = UIApplication.shared.delegate as? CarPlayAppDelegate else { return }
            delegate.consumeBackgroundCompletionHandler(forIdentifier: identifier)?()
            #endif
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodClientCertificate {
            let challengeHost = challenge.protectionSpace.host
            Task {
                let connectionId = await MainActor.run {
                    self.providerConnections.connections.first { conn in
                        conn.mtlsEnabled && URL(string: conn.url)?.host == challengeHost
                    }?.id
                }
                await MainActor.run {
                    let identity = connectionId.flatMap { MTLSManager.shared.identity(for: $0) }
                    if let identity {
                        completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
                    } else {
                        completionHandler(.performDefaultHandling, nil)
                    }
                }
            }
            return
        }

        if method == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        {
            if NetworkHostUtils.isLocalNetworkHost(challenge.protectionSpace.host) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        var redirected = request
        if let originalAuth = task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
            redirected.value(forHTTPHeaderField: "Authorization") == nil
        {
            redirected.setValue(originalAuth, forHTTPHeaderField: "Authorization")
            AppLogger.network.info("Re-applied auth header through redirect to \(redirected.url?.host ?? "?")")
        }
        completionHandler(redirected)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription else { return }
        let parts = description.split(separator: "|")
        guard parts.count == 2 else { return }
        let taskId = String(parts[0])
        let bookId = String(parts[1])

        guard isActiveDownloadTask(taskId: taskId, bookId: bookId) else {
            AppLogger.network.debug("Ignoring removed download completion diagnosticID=\(diagnosticID(bookId))")
            return
        }

        if let httpResponse = downloadTask.response as? HTTPURLResponse,
            !(200...299).contains(httpResponse.statusCode)
        {

            var errorMsg = "Server returned error \(httpResponse.statusCode)"
            if let data = try? Data(contentsOf: location),
                let body = String(data: data, encoding: .utf8)
            {
                let truncated = body.prefix(200)
                errorMsg += ": \(truncated)"
            }

            AppLogger.network.error("Download failed with status \(httpResponse.statusCode)")

            do {
                if try destinations.removeBookDirectory(for: bookId) {
                    AppLogger.network.info("Cleaned up partial download directory")
                }
            } catch {
                AppLogger.network.error(
                    "Failed to clean up partial download directory diagnosticID=\(diagnosticID(bookId)): \(error)"
                )
            }

            let finalErrorMsg = errorMsg
            Task { @MainActor [weak self] in
                guard let self, self.isActiveDownloadTask(taskId: taskId, bookId: bookId) else { return }
                self.updateTask(taskId) {
                    $0.status = .failed
                    $0.errorMessage = finalErrorMsg
                }
                self.activeURLTasks.removeValue(forKey: bookId)
                self.expectedBytesByTaskId.removeValue(forKey: taskId)
                NotificationCenter.default.post(name: UnifiedDownloadService.downloadFailedNotification, object: bookId)
            }
            return
        }

        if let httpResponse = downloadTask.response as? HTTPURLResponse,
            let ct = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        {
            if ct.contains("text/html") || ct.contains("text/plain") {
                let snippet: String
                if let data = try? Data(contentsOf: location, options: .mappedIfSafe) {
                    snippet = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
                } else {
                    snippet = "<unreadable>"
                }
                let errorMsg = "Server returned \(ct) instead of audio. Re-authentication may be needed. (\(String(snippet.prefix(80))))"
                AppLogger.network.error("Non-audio content: \(errorMsg)")
                try? FileManager.default.removeItem(at: location)
                Task { @MainActor [weak self] in
                    guard let self, self.isActiveDownloadTask(taskId: taskId, bookId: bookId) else { return }
                    self.updateTask(taskId) {
                        $0.status = .failed
                        $0.errorMessage = errorMsg
                    }
                    self.activeURLTasks.removeValue(forKey: bookId)
                    self.expectedBytesByTaskId.removeValue(forKey: taskId)
                    NotificationCenter.default.post(name: UnifiedDownloadService.downloadFailedNotification, object: bookId)
                }
                return
            }
        }

        if Self.detectExtensionFromMagicBytes(at: location) == nil {
            if let data = try? Data(contentsOf: location, options: .mappedIfSafe),
                data.count < 50_000,
                let text = String(data: data.prefix(512), encoding: .utf8),
                text.lowercased().contains("<!doctype") || text.lowercased().contains("<html")
            {
                let errorMsg = "Downloaded file is an HTML page, not audio. This usually means the server requires re-authentication."
                AppLogger.network.warning("HTML content detected diagnosticID=\(diagnosticID(bookId))")
                try? FileManager.default.removeItem(at: location)
                Task { @MainActor [weak self] in
                    guard let self, self.isActiveDownloadTask(taskId: taskId, bookId: bookId) else { return }
                    self.updateTask(taskId) {
                        $0.status = .failed
                        $0.errorMessage = errorMsg
                    }
                    self.activeURLTasks.removeValue(forKey: bookId)
                    self.expectedBytesByTaskId.removeValue(forKey: taskId)
                    NotificationCenter.default.post(name: UnifiedDownloadService.downloadFailedNotification, object: bookId)
                }
                return
            }
        }

        let destinationDir = destinations.bookDirectory(for: bookId)
        let destinationExt = Self.detectAudioExtension(
            urlPathExtension: downloadTask.originalRequest?.url?.pathExtension.lowercased(),
            response: downloadTask.response,
            fileURL: location
        )
        let destinationURL = DownloadDestinationFileSystem.chapterFile(
            in: destinationDir,
            index: 0,
            fileExtension: destinationExt
        )

        guard isActiveDownloadTask(taskId: taskId, bookId: bookId) else {
            AppLogger.network.debug("Ignoring removed download completion diagnosticID=\(diagnosticID(bookId))")
            return
        }

        do {
            try destinations.prepareBookDirectory(for: bookId)

            if destinationExt == "zip" || DownloadArchiveFileSystem.isZipFile(at: location) {
                AppLogger.network.debug("ZIP archive detected diagnosticID=\(diagnosticID(bookId)); extracting")
                let extractedAudioURLs = try DownloadArchiveFileSystem.extractZip(at: location, to: destinationDir)
                AppLogger.network.debug("Extracted ZIP audio files diagnosticID=\(diagnosticID(bookId)) count=\(extractedAudioURLs.count)")
            } else {
                try DownloadDestinationFileSystem.replaceItem(at: destinationURL, with: location)
            }

            guard isActiveDownloadTask(taskId: taskId, bookId: bookId) else {
                do {
                    if try destinations.removeBookDirectory(for: bookId) {
                        AppLogger.network.debug("Removed files after download deletion diagnosticID=\(diagnosticID(bookId))")
                    }
                } catch {
                    AppLogger.network.error(
                        "Failed to remove files after download deletion diagnosticID=\(diagnosticID(bookId)): \(error)"
                    )
                }
                return
            }

            Task { @MainActor [weak self] in
                guard let self, self.isActiveDownloadTask(taskId: taskId, bookId: bookId) else { return }
                self.updateTask(taskId) {
                    $0.status = .completed
                    $0.progress = 1.0
                }
                self.activeURLTasks.removeValue(forKey: bookId)
                self.expectedBytesByTaskId.removeValue(forKey: taskId)
                self.resumeData.removeValue(forKey: bookId)
                BookDownloadManager.shared.markAsCompleted(bookId: bookId)
                NotificationCenter.default.post(name: UnifiedDownloadService.downloadCompletedNotification, object: bookId)
                AppLogger.network.debug("Download completed diagnosticID=\(diagnosticID(bookId))")
            }
        } catch {
            let errorMessage = error.localizedDescription
            AppLogger.network.error("Failed to persist or extract download diagnosticID=\(diagnosticID(bookId)): \(error)")

            do {
                if try destinations.removeBookDirectory(for: bookId) {
                    AppLogger.network.error("Cleaned up partial download directory after move error")
                }
            } catch {
                AppLogger.network.error(
                    "Failed to clean up partial download directory after move error diagnosticID=\(diagnosticID(bookId)): \(error)"
                )
            }

            Task { @MainActor [weak self] in
                guard let self, self.isActiveDownloadTask(taskId: taskId, bookId: bookId) else { return }
                self.updateTask(taskId) {
                    $0.status = .failed
                    $0.errorMessage = errorMessage
                }
                self.activeURLTasks.removeValue(forKey: bookId)
                self.expectedBytesByTaskId.removeValue(forKey: taskId)
                NotificationCenter.default.post(name: UnifiedDownloadService.downloadFailedNotification, object: bookId)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let description = downloadTask.taskDescription else { return }
        let parts = description.split(separator: "|")
        guard parts.count == 2 else { return }
        let taskId = String(parts[0])

        Task { @MainActor [weak self] in
            guard let self else { return }
            let taskExpected =
                totalBytesExpectedToWrite > 0
                ? totalBytesExpectedToWrite
                : (self.expectedBytesByTaskId[taskId] ?? -1)

            let progress =
                taskExpected > 0
                ? Double(totalBytesWritten) / Double(taskExpected)
                : 0

            guard self.shouldEmitProgressUpdate(taskId: taskId, progress: progress) else { return }
            self.updateTask(taskId, persist: false) {
                $0.progress = progress
                $0.bytesDownloaded = totalBytesWritten
                $0.totalBytes = taskExpected > 0 ? taskExpected : totalBytesExpectedToWrite
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
            let description = downloadTask.taskDescription,
            let error = error
        else { return }

        let parts = description.split(separator: "|")
        guard parts.count == 2 else { return }
        let taskId = String(parts[0])
        let bookId = String(parts[1])

        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled {
            if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                Task { @MainActor [weak self] in
                    guard let self, self.isActiveDownloadTask(taskId: taskId, bookId: bookId) else { return }
                    self.resumeData[bookId] = resumeData
                    self.expectedBytesByTaskId.removeValue(forKey: taskId)
                }
            }
            return
        }

        let errorMessage = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.isActiveDownloadTask(taskId: taskId, bookId: bookId) else { return }
            self.updateTask(taskId) {
                $0.status = .failed
                $0.errorMessage = errorMessage
            }
            self.activeURLTasks.removeValue(forKey: bookId)
            self.expectedBytesByTaskId.removeValue(forKey: taskId)
            self.resumeData.removeValue(forKey: bookId)
            NotificationCenter.default.post(name: UnifiedDownloadService.downloadFailedNotification, object: bookId)
        }
    }
}
