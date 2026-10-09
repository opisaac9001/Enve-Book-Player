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
    static var shared: UnifiedDownloadService { ProfileSession.owner.downloads }
    static let backgroundSessionIdentifier = "com.narrator.downloads"

    static func backgroundSessionIdentifier(for profileID: String) -> String {
        profileID == FamilyProfile.ownerID
            ? backgroundSessionIdentifier
            : "\(backgroundSessionIdentifier).profile.\(profileID)"
    }

    static func profileID(forBackgroundSessionIdentifier identifier: String) -> String? {
        if identifier == backgroundSessionIdentifier { return FamilyProfile.ownerID }
        let prefix = "\(backgroundSessionIdentifier).profile."
        guard identifier.hasPrefix(prefix) else { return nil }
        let profileID = String(identifier.dropFirst(prefix.count))
        return FamilyProfile.validID(profileID) ? profileID : nil
    }

    func handleBackgroundSession(identifier: String) {
        guard !isRetired,
            identifier == Self.backgroundSessionIdentifier(for: storageLocations.profileID)
        else { return }
        _ = urlSession
    }

    func recordCompletedImport(_ book: Book) {
        guard !isRetired else { return }
        tasks.removeAll { $0.bookId == book.downloadKey }
        var task = BookDownloadTask.create(bookId: book.downloadKey, title: book.title, source: book.source)
        task.status = .completed
        task.progress = 1
        tasks.append(task)
        saveQueue()
    }

    @Published private(set) var tasks: [BookDownloadTask] = [] {
        didSet {

            activeTaskBookIdsMirrorLock.lock()
            let activeTasks = tasks.filter { $0.isActive }
            downloadManager.activity.unifiedBookIDs = Set(activeTasks.map { $0.bookId })
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
        defaults.bool(forKey: "allowCellularBookDownloads")
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

    private var backgroundURLSession: URLSession?
    private var urlSession: URLSession? {
        if let backgroundURLSession { return backgroundURLSession }
        guard !isRetired else { return nil }
        let config = NetworkPolicyService.shared.makeBackgroundSessionConfiguration(
            identifier: Self.backgroundSessionIdentifier(for: storageLocations.profileID), allowCellular: true,
            isolatesCredentials: storageLocations.profileID != FamilyProfile.ownerID
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        backgroundURLSession = session
        return session
    }

    func start() {
        guard !isRetired, !hasStarted else { return }
        hasStarted = true
        setupNetworkMonitor()
        if tasks.contains(where: { $0.isActive }) { _ = urlSession }
        maintenanceTask = Task { [weak self] in
            guard let self, !self.isRetired, !Task.isCancelled else { return }
            await self.cleanupFailedDownloads()
            guard !self.isRetired, !Task.isCancelled else { return }
            await self.checkStorageLimit()
        }
    }
    private var foregroundURLSession: URLSession!
    private var activeURLTasks: [String: URLSessionDownloadTask] = [:]
    private var readerAssetOperations: [String: (id: UUID, task: Task<URL, Error>)] = [:]
    private var storytellerReadaloudCacheTasks: [String: (id: UUID, task: Task<URL, Error>)] = [:]
    private var expectedBytesByTaskId: [String: Int64] = [:]
    private var resumeData: [String: Data] = [:]
    private var lastProgressEmissionByTaskId: [String: (time: Date, progress: Double)] = [:]
    private let networkMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.narrator.download.network")
    let storageManager: LocalStorageManager
    private let storageLocations: ProfileStorageLocations
    private let defaults: UserDefaults
    private let ebookImporter: LocalEbookImporter
    private let localLibrary: LocalLibraryStorageStore
    private let preferences: LibraryDisplayPreferencesStore
    private let readerArtifacts: ReaderArtifactsStore
    private let downloadManager: BookDownloadManager
    private let clientCertificate: @Sendable (String) async -> URLCredential?
    let imageCache: DiskImageCache
    let localMetadata = LocalLibraryService()
    private let audiobookshelfService: AudiobookshelfService
    private let smbLibrary: SMBLibraryService?
    private let legacyABSBackend: BackendConfig?
    private let downloadPlans = DownloadPlanRegistry.shared
    private let destinations: DownloadDestinationFileSystem
    private var isRetired = false
    private var hasStarted = false
    private var maintenanceTask: Task<Void, Never>?
    private var runningDownloads: [String: Task<Void, Never>] = [:]
    private var invalidationContinuations: [ObjectIdentifier: CheckedContinuation<Void, Never>] = [:]
    let providerConnections: any ProviderConnectionAccessing
    private let presentation: AppPresentationState
    private let bookQuerying: any BookQuerying
    private let bookWriting: any BookWriting
    private let libraryCache: any DownloadLibraryCaching
    private let queueStore: UnifiedDownloadQueueStore
    private let minProgressUpdateInterval: TimeInterval = 0.25
    private let minProgressDelta: Double = 0.005

    static let downloadCompletedNotification = Notification.Name("UnifiedDownloadCompleted")
    static let downloadFailedNotification = Notification.Name("UnifiedDownloadFailed")

    private init(
        providerConnections: any ProviderConnectionAccessing,
        presentation: AppPresentationState,
        bookQuerying: any BookQuerying,
        bookWriting: any BookWriting,
        libraryCache: any DownloadLibraryCaching,
        storageLocations: ProfileStorageLocations,
        defaults: UserDefaults,
        storageManager: LocalStorageManager,
        ebookImporter: LocalEbookImporter,
        localLibrary: LocalLibraryStorageStore,
        preferences: LibraryDisplayPreferencesStore,
        readerArtifacts: ReaderArtifactsStore,
        downloadManager: BookDownloadManager,
        queueStore: UnifiedDownloadQueueStore,
        clientCertificate: @escaping @Sendable (String) async -> URLCredential?
    ) {
        self.providerConnections = providerConnections
        self.presentation = presentation
        self.bookQuerying = bookQuerying
        self.bookWriting = bookWriting
        self.libraryCache = libraryCache
        self.storageLocations = storageLocations
        self.defaults = defaults
        self.storageManager = storageManager
        self.ebookImporter = ebookImporter
        self.localLibrary = localLibrary
        self.preferences = preferences
        self.readerArtifacts = readerArtifacts
        self.downloadManager = downloadManager
        self.queueStore = queueStore
        self.clientCertificate = clientCertificate
        smbLibrary = storageLocations.profileID == FamilyProfile.ownerID ? .shared : nil
        if storageLocations.profileID == FamilyProfile.ownerID,
            let credentials = try? SecureTokenStorage.shared.loadCredentials(forService: "audiobookshelf")
        {
            legacyABSBackend = BackendConfig(
                id: "audiobookshelf_legacy", name: "Audiobookshelf", type: .audiobookshelf,
                url: credentials.serverUrl, token: credentials.token, enabled: true,
                username: credentials.username, password: nil, userId: nil, selectedLibraryIds: nil
            )
        } else {
            legacyABSBackend = nil
        }
        imageCache = storageLocations.profileID == FamilyProfile.ownerID ? .shared : DiskImageCache(
            cacheDirectory: storageLocations.cachesDirectory.appendingPathComponent("BookCovers", isDirectory: true)
        )
        audiobookshelfService = AudiobookshelfService(session: URLSession(configuration:
            NetworkPolicyService.shared.makeSessionConfiguration(
                allowCellular: true, isolatesCredentials: storageLocations.profileID != FamilyProfile.ownerID
            )
        ))
        destinations = DownloadDestinationFileSystem(audiobooksRoot: storageManager.audiobooksDirectory)
        super.init()

        loadQueue()

        let foregroundConfig = NetworkPolicyService.shared.makeSessionConfiguration(
            allowCellular: true, isolatesCredentials: storageLocations.profileID != FamilyProfile.ownerID
        )
        foregroundConfig.allowsCellularAccess = true
        foregroundConfig.waitsForConnectivity = true
        foregroundConfig.timeoutIntervalForRequest = 600
        foregroundConfig.timeoutIntervalForResource = 7200
        foregroundURLSession = URLSession(configuration: foregroundConfig, delegate: self, delegateQueue: nil)

        AppLogger.network.info("UnifiedDownloadService initialized")
    }

    convenience init(
        storage: ProfileStorageLocations,
        defaults: UserDefaults,
        storageManager: LocalStorageManager,
        ebookImporter: LocalEbookImporter,
        localLibrary: LocalLibraryStorageStore,
        preferences: LibraryDisplayPreferencesStore,
        readerArtifacts: ReaderArtifactsStore,
        downloadManager: BookDownloadManager,
        providerConnections: any ProviderConnectionAccessing,
        presentation: AppPresentationState,
        bookQuerying: any BookQuerying,
        bookWriting: any BookWriting,
        libraryCache: any DownloadLibraryCaching,
        clientCertificate: @escaping @Sendable (String) async -> URLCredential?
    ) throws {
        self.init(
            providerConnections: providerConnections, presentation: presentation,
            bookQuerying: bookQuerying, bookWriting: bookWriting, libraryCache: libraryCache,
            storageLocations: storage, defaults: defaults, storageManager: storageManager,
            ebookImporter: ebookImporter, localLibrary: localLibrary, preferences: preferences,
            readerArtifacts: readerArtifacts, downloadManager: downloadManager,
            queueStore: try UnifiedDownloadQueueStore(storage: storage), clientCertificate: clientCertificate
        )
    }

    func retire() async {
        guard !isRetired else { return }
        isRetired = true
        networkMonitor.cancel()
        maintenanceTask?.cancel()
        let downloads = Array(runningDownloads.values)
        downloads.forEach { $0.cancel() }
        let readerJobs = readerAssetOperations.values.map(\.task) + storytellerReadaloudCacheTasks.values.map(\.task)
        readerJobs.forEach { $0.cancel() }
        for index in tasks.indices where tasks[index].isActive {
            tasks[index].status = .paused
        }
        saveQueue()
        for session in [backgroundURLSession, foregroundURLSession].compactMap({ $0 }) {
            await withCheckedContinuation { continuation in
                invalidationContinuations[ObjectIdentifier(session)] = continuation
                session.invalidateAndCancel()
            }
        }
        await downloadManager.retire()
        for job in downloads { await job.value }
        for job in readerJobs { _ = try? await job.value }
        await maintenanceTask?.value
        activeURLTasks.removeAll()
        runningDownloads.removeAll()
        readerAssetOperations.removeAll()
        storytellerReadaloudCacheTasks.removeAll()
        saveQueue()
    }

    private func setupNetworkMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let isAvailable = path.status == .satisfied
            let isExpensive = path.isExpensive
            Task { @MainActor [weak self] in
                guard let self, !self.isRetired else { return }
                self.isNetworkAvailable = isAvailable
                self.isOnCellular = isExpensive
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
        guard !isRetired, let index = tasks.firstIndex(where: { $0.id == taskId }) else { return }

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
        guard !isRetired else { return }
        lastError = nil

        let bookId = book.downloadKey

        let isSMBBook = book.source == .smb

        if !isSMBBook && book.mediaType != .ebook && storageManager.isAudiobookDownloaded(bookId) {
            AppLogger.network.debug("Book already downloaded diagnosticID=\(diagnosticID(book.stableId))")
            return
        }

        tasks.removeAll { $0.bookId == bookId && ($0.status == .completed || $0.status == .failed || $0.status == .cancelled) }

        let hasActiveTaskEntry = tasks.contains(where: { $0.bookId == bookId && $0.isActive })
        if hasActiveTaskEntry {
            let hasLiveURLTask = activeURLTasks[bookId] != nil
            let hasLiveExternalTask = downloadManager.activeBookIds.contains(bookId)

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
        if book.source == .storyteller, book.epub3Features?.hasMediaOverlay == true {
            return ebookImporter.resolveEbookForOverlay(book: book)
        }
        if book.epub3Features?.hasMediaOverlay == true,
            let readaloud = ebookImporter.resolveEbookForOverlay(book: book)
        {
            return readaloud
        }
        return ebookImporter.resolveExistingLocalEbookURL(
            bookIdentifier: book.id,
            ebookFileURL: book.ebookFileURL,
            filePath: book.mediaType == .ebook ? book.filePath : nil
        )
    }

    func prepareReaderAsset(
        for book: Book,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard !isRetired else { throw CancellationError() }
        if let sourceID = book.readAloudSourceStableId {
            guard let source = await bookQuerying.book(stableId: sourceID),
                source.mediaType == .ebook, source.readAloudSourceStableId == nil
            else { throw ProfileDownloadImportError.missingMedia }
            return try await prepareReaderAsset(for: source, onProgress: onProgress)
        }
        if book.source == .storyteller, book.epub3Features?.hasMediaOverlay == true {
            return try await ensureStorytellerReadaloudCached(for: book, onProgress: onProgress)
        }

        if let existing = existingReaderAsset(for: book) {
            return existing
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
            guard !isRetired else { throw CancellationError() }
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
        guard !isRetired else { throw CancellationError() }
        guard book.source == .storyteller, book.epub3Features?.hasMediaOverlay == true else {
            throw NSError(
                domain: "UnifiedDownloadService",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "This Storyteller book is not a read-aloud EPUB."
                ]
            )
        }

        let existingReadaloudURL = ebookImporter.resolveEbookForOverlay(book: book)
        #if os(tvOS)
            let hasExistingReadaloud = existingReadaloudURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        #else
            let hasExistingReadaloud: Bool
            if let existingReadaloudURL {
                hasExistingReadaloud = (try? await StorytellerReadaloudOfflinePrep.validate(epubURL: existingReadaloudURL)) != nil
            } else {
                hasExistingReadaloud = false
            }
        #endif
        if let existingURL = existingReadaloudURL, hasExistingReadaloud {
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
            guard !isRetired else { throw CancellationError() }
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
        guard !isRetired else { return }
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

        downloadManager.cancelDownload(bookId: task.bookId)

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

    func reassignInactiveDownloadTasks(fromBookId oldId: String, toBookId newId: String) {
        var updated = tasks
        var didChange = false
        for index in updated.indices where updated[index].bookId == oldId && !updated[index].isActive {
            let task = updated[index]
            updated[index] = BookDownloadTask(
                id: task.id,
                bookId: newId,
                title: task.title,
                source: task.source,
                status: task.status,
                progress: task.progress,
                bytesDownloaded: task.bytesDownloaded,
                totalBytes: task.totalBytes,
                errorMessage: task.errorMessage,
                createdAt: task.createdAt,
                updatedAt: task.updatedAt
            )
            didChange = true
        }
        guard didChange else { return }
        tasks = updated
        saveQueue()
    }

    func retry(taskId: String, book: Book) async {
        guard !isRetired else { return }
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
        guard !isRetired else { return }
        if book.mediaType == .ebook {
            do {
                if book.source == .local, book.backendId == "profile-imports" {
                    let root = ebookImporter.localEbooksRoot
                    let directory = root.appendingPathComponent(book.id, isDirectory: true)
                    try LocalStorageManager.validateImportPath(directory, within: root)
                    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                } else if book.source != .local {
                    try ebookImporter.deleteRemoteEbookArtifacts(forBookId: book.id)
                    ebookImporter.removeReadaloudCache(forBookId: book.id, stableId: book.stableId)
                } else { return }
                var updated = book
                updated.ebookFileURL = nil
                await bookWriting.upsertBooks([updated])
                libraryCache.mutateBook(uniqueId: book.uniqueId) {
                    $0.ebookFileURL = nil
                }
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
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

        for session in [backgroundURLSession, foregroundURLSession].compactMap({ $0 }) {
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
            downloadManager.cancelDownload(bookId: bookId)
            downloadManager.clearState(bookId: bookId)
        }

        await Task.detached(priority: .utility) { [storageManager] in
            for bookId in bookIds {
                _ = await storageManager.deleteAudiobook(bookId)
            }
        }.value

        openBookIds.subtract(bookIds)
        NotificationCenter.default.post(name: .localLibraryUpdated, object: nil)
        NotificationCenter.default.post(name: .bookStoreDidChange, object: nil)
    }

    func downloadFileCopy(bookId: String, title: String, sourceURL: URL, securityScopedRootURL: URL? = nil) async {
        guard !isRetired else { return }
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

        await downloadManager.startFileCopyDownload(
            bookId: bookId,
            sourceURL: sourceURL,
            securityScopedRootURL: securityScopedRootURL
        )
        await monitorExternalDownload(taskId: task.id, bookId: bookId)
    }

    func cleanupFailedDownloads() async {
        let prefs = preferences.loadPreferences()
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
        let prefs = preferences.loadPreferences()
        guard prefs.storageLimitEnabled else { return }

        let limitBytes = Int64(prefs.storageLimitGB) * 1024 * 1024 * 1024

        let currentUsage = storageManager.totalDownloadedMediaSize()

        if currentUsage > limitBytes {
            AppLogger.network.info(
                "Storage limit exceeded: \(ByteCountFormatter.string(fromByteCount: currentUsage, countStyle: .file)) > \(ByteCountFormatter.string(fromByteCount: limitBytes, countStyle: .file))"
            )

            let allBooks = storageManager.getOldestDownloadedBookIds()
            var bytesToFre = currentUsage - limitBytes

            for (bookId, _) in allBooks {
                if bytesToFre <= 0 || isRetired || Task.isCancelled { break }
                guard !openBookIds.contains(bookId), !downloadManager.activity.isActive(bookId) else { continue }

                let size = storageManager.sizeOfAudiobook(bookId)
                if storageManager.deleteAudiobook(bookId) {
                    bytesToFre -= size
                    AppLogger.network.info(
                        "Storage limit auto-clean diagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookId)) bytes=\(size)"
                    )

                    await MainActor.run {
                        self.removeTaskForBook(bookId)
                    }
                }
            }

            if bytesToFre > 0 {
                let ebookBooks = await bookQuerying.allBooks().filter { book in
                    book.mediaType == .ebook && completedTasks.contains { $0.bookId == book.downloadKey }
                }.sorted { $0.lastUpdate < $1.lastUpdate }
                for book in ebookBooks {
                    if bytesToFre <= 0 || isRetired || Task.isCancelled { break }
                    guard !storageManager.hasActiveDownload(for: book), !openBookIds.contains(book.downloadKey) else { continue }
                    let before = storageManager.totalEbookSize()
                    await deleteDownload(book: book)
                    bytesToFre -= max(0, before - storageManager.totalEbookSize())
                }
            }
            NotificationCenter.default.post(name: .localLibraryUpdated, object: nil)
        }
    }

    private func removeTaskForBook(_ bookId: String) {
        if let task = tasks.first(where: { $0.bookId == bookId }) {
            remove(taskId: task.id)
        }
    }

    private var openBookIds: Set<String> = []

    private func startDownload(task: inout BookDownloadTask, book: Book) async {
        guard !isRetired else { return }
        let downloadTask = task
        let operation = Task { await executeDownload(task: downloadTask, book: book) }
        runningDownloads[task.id] = operation
        await operation.value
        runningDownloads.removeValue(forKey: task.id)
    }

    private func executeDownload(task: BookDownloadTask, book: Book) async {
        updateTask(task.id) { $0.status = .downloading }

        do {
            let plan = try downloadPlans.plan(for: book)
            try await plan.execute(using: self, task: task, book: book)

            try Task.checkCancellation()
            await cacheAssetsForOffline(book: book)

        } catch is CancellationError {
            guard !isRetired else { return }
            updateTask(task.id) {
                $0.status = .cancelled
                $0.errorMessage = nil
            }
            AppLogger.network.debug("Download cancelled diagnosticID=\(diagnosticID(book.stableId))")
        } catch {
            guard !isRetired else { return }
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
            try? FileManager.default.removeItem(at: url)
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
            let item = try await audiobookshelfService.getLibraryItem(id: itemId, backend: backend, expanded: true)

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

            let (tempURL, response) = try await foregroundURLSession.download(for: request)

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
        downloadManager.markAsCompleted(bookId: task.bookId)
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
                    let _ = try await audiobookshelfService.getLibraryItem(id: itemId, backend: backend)
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

        if let legacyABSBackend { return legacyABSBackend }

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
        defer { downloader.cancel() }
        downloader.start()

        while !Task.isCancelled && !isRetired {
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

        try Task.checkCancellation()
        guard !isRetired else { throw CancellationError() }
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
            self?.downloadManager.markAsCompleted(bookId: bookId)
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
                downloadManager.markAsCompleted(bookId: bundleBook.downloadKey)
                NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: bundleBook.downloadKey)
                await refreshOfflineMetadataFromDownloadedFiles(book: bundleBook, bookId: bundleBook.downloadKey)
            } catch {
                AppLogger.network.error("Failed to route Real-Debrid archive diagnosticID=\(diagnosticID(bundleBook.stableId)): \(error.localizedDescription)")
            }
        }
    }

    private func realDebridArchiveBooks(for book: Book, archiveURL: String) async -> [Book] {
        guard book.source == .realdebrid else { return [book] }

        let providerBooks = await bookQuerying.books(source: Book.BookSource.realdebrid.rawValue, providerId: book.providerId)
        let matched = providerBooks.filter { candidate in
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
        downloadManager.markAsCompleted(bookId: task.bookId)
        NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: task.bookId)
        AppLogger.network.info("[WebDAV Download] Multi-file download completed: \(totalFiles) files")
    }

    func downloadFromSMB(task: BookDownloadTask, book: Book) async throws {
        guard let smbLibrary else {
            throw DownloadError.missingCredentials("This SMB source is not configured for this profile")
        }
        guard let sourceId = book.backendId else {
            throw DownloadError.missingCredentials("SMB source not found")
        }

        let sources = await smbLibrary.getSources()
        guard let source = sources.first(where: { $0.id == sourceId }) else {
            throw DownloadError.missingCredentials("SMB source not configured")
        }

        guard let password = await smbLibrary.getPassword(for: sourceId) else {
            throw DownloadError.missingCredentials("SMB password not found")
        }

        let smbBooks = await smbLibrary.getBooks(for: sourceId)
        guard let smbBook = smbBooks.first(where: { $0.id == book.id }) else {
            throw DownloadError.fileNotFound
        }

        let taskId = task.id
        let bookId = task.bookId

        await MainActor.run {
            downloadManager.clearCompletedState(bookId: bookId)
        }

        AppLogger.network.debug("[SMB Download] Starting diagnosticID=\(diagnosticID(book.stableId))")

        let monitorTask = Task {
            while !Task.isCancelled && !isRetired {
                try? await Task.sleep(nanoseconds: 1_000_000_000)

                let isCompleted = await MainActor.run {
                    downloadManager.completedBookIds.contains(bookId)
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
                    downloadManager.activeBookIds.contains(bookId)
                }
                if !isActive {
                    if let error = await MainActor.run(body: { downloadManager.lastErrorByBookId[bookId] }) {
                        AppLogger.network.error("[SMB Download] Failed diagnosticID=\(diagnosticID(bookId)): \(error)")
                        self.updateTask(taskId) {
                            $0.status = .failed
                            $0.errorMessage = error
                        }
                        return
                    }

                    let finalCheck = await MainActor.run {
                        downloadManager.completedBookIds.contains(bookId)
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
                    downloadManager.progressByBookId[bookId] ?? 0
                }
                if self.shouldEmitProgressUpdate(taskId: taskId, progress: progress) {
                    self.updateTask(taskId, persist: false) { $0.progress = progress }
                }
            }
        }

        await downloadManager.startSMBDownload(
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

        let offlineURL = try ebookImporter.persistRemoteEbookForOffline(
            from: downloadedURL,
            preferredFilename: downloadedURL.lastPathComponent,
            bookIdentifier: book.id
        )
        try Task.checkCancellation()

        #if os(iOS)
        let features = offlineURL.pathExtension.caseInsensitiveCompare("epub") == .orderedSame
            ? await EPUB3SMILParser.detectFeatures(epubFileURL: offlineURL) : nil
        #else
        let features: EPUB3Features? = nil
        #endif
        try Task.checkCancellation()
        guard !isRetired else { throw CancellationError() }
        var updated = await bookQuerying.book(uniqueId: book.uniqueId) ?? book
        try Task.checkCancellation()
        guard !isRetired else { throw CancellationError() }
        updated = libraryCache.mutateBook(uniqueId: book.uniqueId) {
            $0.ebookFileURL = offlineURL
            if let features { $0.epub3Features = features }
        } ?? updated
        updated.ebookFileURL = offlineURL
        if let features { updated.epub3Features = features }
        await bookWriting.upsertBooks([updated])
        try Task.checkCancellation()
        guard !isRetired else { throw CancellationError() }

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
        downloadManager.markAsCompleted(bookId: task.bookId)
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
            || readerArtifacts.loadCachedChapters(bookId: book.stableId)?.isEmpty == false
            || readerArtifacts.loadCachedChapters(bookId: book.id)?.isEmpty == false

        let audioDir = storageManager.bookAudioDirectory(for: book.downloadKey)
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
            await downloadManager.startMultiTrackHTTPDownload(bookId: downloadKey, requests: requests)
        } else {
            await downloadManager.startDownload(bookId: downloadKey, request: requests[0].request)
        }

        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 500_000_000)
            try Task.checkCancellation()

            let isComplete = await MainActor.run { downloadManager.completedBookIds.contains(downloadKey) }
            if isComplete {
                updateTask(task.id) {
                    $0.status = .completed
                    $0.progress = 1.0
                }
                NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: task.bookId)
                AppLogger.network.debug("Audiobook downloaded source=\(book.source.rawValue) diagnosticID=\(diagnosticID(book.stableId))")
                return
            }

            if let errorMsg = await MainActor.run(body: { downloadManager.lastErrorByBookId[downloadKey] }) {
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
                AppLogger.network.info("[Booklore] /info returned \(trackInfos.count) tracks for download")
                return trackInfos.compactMap { info in
                    var req = URLRequest(url: info.url)
                    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
                    return (request: req, mimeType: info.mimeType)
                }
            }
            if let session = try? await provider.startPlaybackSession(for: book),
                session.audioTracks.count > 1
            {
                AppLogger.network.info("[Booklore] session fallback returned \(session.audioTracks.count) tracks for download")
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
                await downloadManager.startMultiTrackHTTPDownload(bookId: downloadKey, requests: trackRequests)
            } else {
                await downloadManager.startDownload(bookId: downloadKey, request: trackRequests[0].request)
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

            let isComplete = await MainActor.run { downloadManager.completedBookIds.contains(downloadKey) }
            if isComplete {
                updateTask(task.id) {
                    $0.status = .completed
                    $0.progress = 1.0
                }
                NotificationCenter.default.post(name: Self.downloadCompletedNotification, object: task.bookId)
                AppLogger.network.debug("Grimmory audiobook downloaded diagnosticID=\(diagnosticID(book.stableId))")
                return
            }

            let hasError = await MainActor.run { downloadManager.lastErrorByBookId[downloadKey] }
            if let errorMsg = hasError {
                let isAuthFailure = errorMsg.contains("401") || errorMsg.lowercased().contains("unauthorized")
                if isAuthFailure && !didRetryOn401 {
                    didRetryOn401 = true
                    AppLogger.network.info("[Booklore] download hit 401; refreshing JWT and retrying once")
                    let refreshed = await provider.refreshStreamingTokenIfNeeded(force: true)
                    if !refreshed {
                        throw NSError(
                            domain: "UnifiedDownloadService",
                            code: 401,
                            userInfo: [NSLocalizedDescriptionKey: "Grimmory download failed: 401 Unauthorized (token refresh failed)"]
                        )
                    }

                    downloadManager.cancelDownload(bookId: downloadKey)
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

            let progress = await MainActor.run { downloadManager.progressByBookId[downloadKey] ?? 0 }
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
            rootURL = storageLocations.documentsDirectory
        } else {
            guard let bookmarkData = localLibrary.loadBookmark(for: libraryId) else {
                throw DownloadError.missingCredentials("Local library not configured")
            }

            var isStale = false
            rootURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)
        }

        let localBook = localLibrary.loadBooks(libraryId: libraryId).first(where: { $0.id == book.id })
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
        await downloadManager.startFileCopyDownload(
            bookId: task.bookId,
            sourceURL: sourceURL,
            securityScopedRootURL: rootURL
        )
        await monitorExternalDownload(taskId: taskId, bookId: bookId)
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
        guard !isRetired, !Task.isCancelled else { return }
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
        let manager = downloadManager

        AppLogger.network.debug("Monitoring SMB download diagnosticID=\(diagnosticID(bookId))")

        while !Task.isCancelled && !isRetired {
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
    nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        Task { @MainActor in
            invalidationContinuations.removeValue(forKey: ObjectIdentifier(session))?.resume()
        }
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

    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod

        if method == NSURLAuthenticationMethodClientCertificate {
            let challengeHost = challenge.protectionSpace.host
            Task {
                let credential = await clientCertificate(challengeHost)
                completionHandler(credential == nil ? .performDefaultHandling : .useCredential, credential)
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

    /// The task's own destination is the only origin its credentials belong to. See `HTTPRedirectPolicy`.
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, HTTPRedirectPolicy.isFollowable(url, from: response.url) else {
            AppLogger.network.warning("Refused an unsafe download redirect")
            completionHandler(nil)
            return
        }

        let origin = HTTPRedirectPolicy.origin(ofOriginalRequestIn: task)
        guard origin?.matches(url) == true else {
            completionHandler(HTTPRedirectPolicy.sanitized(request, keepingCredentialsFor: origin))
            return
        }

        var redirected = request
        if let originalAuth = task.originalRequest?.value(forHTTPHeaderField: "Authorization"),
            redirected.value(forHTTPHeaderField: "Authorization") == nil
        {
            redirected.setValue(originalAuth, forHTTPHeaderField: "Authorization")
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
                self.downloadManager.markAsCompleted(bookId: bookId)
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
