import Combine
import Foundation
import Logging

struct SyncSnapshot: Sendable {
    let progress: Double
    let positionSeconds: TimeInterval
    let locator: String?
    let lastUpdate: Date
    let isFinished: Bool
    let source: String
}

func freshestEbookProgressBook(captured: Book, cached: Book?) -> Book {
    guard let cached else { return captured }
    if cached.lastUpdate > captured.lastUpdate { return cached }
    if cached.lastUpdate < captured.lastUpdate { return captured }
    if cached.epubLocator != nil || cached.ebookProgress != nil { return cached }
    return captured
}

@MainActor
final class PerBookSerialQueue {
    private var active: [String: Task<Void, Never>] = [:]
    private var tokens: [String: UUID] = [:]

    func enqueue(bookId: String, operation: @escaping () async -> Void) async {
        let prior = active[bookId]
        let token = UUID()
        let task = Task { @MainActor in
            _ = await prior?.result
            await operation()
        }
        active[bookId] = task
        tokens[bookId] = token
        await task.value
        if tokens[bookId] == token {
            active[bookId] = nil
            tokens[bookId] = nil
        }
    }
}

@MainActor
@Observable
final class SyncCoordinator {
    static let shared: SyncCoordinator = {
        let appState = AppState.shared
        let coordinator = SyncCoordinator(
            providerResolver: appState.providerConnections,
            pendingSyncFlusher: PendingSyncQueueFlusher(
                transport: ProviderPendingSyncTransport(
                    providerResolver: appState.providerConnections,
                    bookLookup: { stableId in
                        await appState.bookStore.book(stableId: stableId)
                    }
                )
            ),
            recentlyPlayedSync: RecentlyPlayedSyncService(
                playbackState: ActivePlayback.controller,
                providerConnections: appState.providerConnections,
                bookQuerying: appState.bookStore,
                bookWriting: appState.bookStore,
                progressRepository: appState.bookStore,
                progressAPI: AudiobookshelfRecentlyPlayedProgressAPI(service: .shared),
                progressCache: BookProgressStore.shared,
                libraryCache: appState,
                ebookLinks: EbookLinkStore.shared,
                strategyRegistry: PluginRegistry.shared
            )
        )
        coordinator.startAppIntegration()
        return coordinator
    }()

    private let serialQueue = PerBookSerialQueue()
    private let providerResolver: any LibraryProviderResolving
    private let pendingSyncFlusher: PendingSyncQueueFlusher
    private let recentlyPlayedSync: any RecentlyPlayedSyncing

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastSyncDeviceName: String?
    private(set) var syncEnabled = true
    private(set) var isCloudKitAvailable = false
    private(set) var isEbookReaderOpen = false
    var pendingSyncCount: Int { PendingSyncQueueStore.shared.count }

    @ObservationIgnored private var eventContinuations: [String: AsyncStream<SyncEvent>.Continuation] = [:]
    @ObservationIgnored private var pushDebounceTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var lifecycleController: SyncLifecycleController?
    @ObservationIgnored private var activeRecentlyPlayedSyncTask: Task<ServerStatusSyncResult, Never>?
    @ObservationIgnored private var activeRecentlyPlayedSyncToken = 0
    private let pushDebounceInterval: TimeInterval = 2.0

    @ObservationIgnored private var lastHardcoverProgress: [String: Double] = [:]
    private let hardcoverThreshold: Double = AppConstants.Sync.hardcoverSyncThreshold

    init(
        providerResolver: any LibraryProviderResolving,
        pendingSyncFlusher: PendingSyncQueueFlusher,
        recentlyPlayedSync: any RecentlyPlayedSyncing
    ) {
        self.providerResolver = providerResolver
        self.pendingSyncFlusher = pendingSyncFlusher
        self.recentlyPlayedSync = recentlyPlayedSync
        loadSettings()
    }

    private func startAppIntegration() {
        setupLifecycle()
        setupReaderObservers()
        ProgressAutoSaver.shared.onTick = {
            _ = await SyncCoordinator.shared.persistCurrentPlayback(reason: .timerInterval)
        }
        Task { @MainActor in
            _ = CloudProgressService.shared
        }
    }

    private func loadSettings() {
        if UserDefaults.standard.object(forKey: "crossDeviceSyncEnabled") == nil {
            syncEnabled = true
            UserDefaults.standard.set(true, forKey: "crossDeviceSyncEnabled")
        } else {
            syncEnabled = UserDefaults.standard.bool(forKey: "crossDeviceSyncEnabled")
        }
    }

    private func setupLifecycle() {
        #if os(iOS)
        lifecycleController = SyncLifecycleController(
            events: .application,
            save: { reason in
                _ = await SyncCoordinator.shared.persistCurrentPlayback(reason: reason)
            },
            enterForeground: {
                await SyncCoordinator.shared.handleForeground()
            }
        )
        lifecycleController?.start()
        #endif
    }

    private func setupReaderObservers() {
        NotificationCenter.default.publisher(for: Notification.Name("ebookReaderPresented"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                isEbookReaderOpen = true
                activeRecentlyPlayedSyncTask?.cancel()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Notification.Name("ebookReaderDismissed"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                isEbookReaderOpen = false
                Task { @MainActor in
                    _ = await self.runRecentlyPlayedSync(trigger: .appLaunch)
                }
            }
            .store(in: &cancellables)
    }

    func setSyncEnabled(_ enabled: Bool) {
        syncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "crossDeviceSyncEnabled")
        enabled ? ProgressAutoSaver.shared.start() : ProgressAutoSaver.shared.stop()
    }

    func enqueuePendingSync(
        book: Book,
        position: TimeInterval,
        duration: TimeInterval,
        serverItemId: String,
        domain: ProgressSyncDomain = .audiobook,
        progress: Double? = nil,
        locator: String? = nil,
        isFinished: Bool? = nil
    ) {
        PendingSyncQueueStore.shared.enqueue(
            PendingServerSync(
                stableId: book.stableId,
                sourceRaw: book.source.rawValue,
                backendId: book.backendId,
                serverItemId: serverItemId,
                position: position,
                duration: duration,
                updatedAt: book.lastUpdate.timeIntervalSince1970,
                domainRaw: domain.usesEbookProgress ? "ebook" : "audiobook",
                progress: progress,
                locator: locator,
                isFinished: isFinished
            )
        )
        AppLogger.sync.debug(
            "Enqueued pending sync for bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
        )
    }

    func flushPendingSyncs() async {
        await pendingSyncFlusher.flush()
    }

    func markSynced(deviceName: String) {
        lastSyncDate = Date()
        lastSyncDeviceName = deviceName
    }

    func beginSync() {
        isSyncing = true
    }

    func endSync(at date: Date? = Date()) {
        isSyncing = false
        if let date { lastSyncDate = date }
    }

    func updateCloudAvailability(_ available: Bool) {
        isCloudKitAvailable = available
        if available, syncEnabled {
            ProgressAutoSaver.shared.start()
        } else {
            ProgressAutoSaver.shared.stop()
        }
    }

    func updateLastSync(date: Date, deviceName: String? = nil) {
        lastSyncDate = date
        if let deviceName { lastSyncDeviceName = deviceName }
    }

    private func handleForeground() async {
        await flushPendingSyncs()
        async let cloudSync: Void = CloudProgressService.shared.syncOnAppLaunch(books: AppState.shared.allBooks)
        async let providerSync: Void = CloudProgressService.shared.refreshCurrentBookFromServer()
        _ = await (cloudSync, providerSync)
    }

    @discardableResult
    func runRecentlyPlayedSync(trigger: ServerStatusSyncTrigger) async -> ServerStatusSyncResult {
        if isEbookReaderOpen, trigger != .homePullToRefresh {
            return .cancelled
        }

        guard !isSyncing else {
            AppLogger.sync.warning("Server status sync already in progress - skipping \(trigger.rawValue)")
            return .idle
        }

        activeRecentlyPlayedSyncTask?.cancel()
        activeRecentlyPlayedSyncToken &+= 1
        let token = activeRecentlyPlayedSyncToken
        beginSync()

        let pendingPushes = Array(pushDebounceTasks.values)
        let task = Task<ServerStatusSyncResult, Never> { @MainActor [pendingSyncFlusher, recentlyPlayedSync] in
            for push in pendingPushes { await push.value }
            await pendingSyncFlusher.flush()
            return await recentlyPlayedSync.sync(trigger: trigger)
        }
        activeRecentlyPlayedSyncTask = task
        let result = await task.value

        if activeRecentlyPlayedSyncToken == token {
            activeRecentlyPlayedSyncTask = nil
            endSync()
        }
        return result
    }

    func syncOnAppLaunch(books: [Book]) async {
        await CloudProgressService.shared.syncOnAppLaunch(books: books)
    }

    func syncNewBooksFromCloud(_ books: [Book]) async {
        await CloudProgressService.shared.syncNewBooksFromCloud(books)
    }

    func getCloudProgress(for book: Book) async -> (position: TimeInterval, deviceName: String?)? {
        await CloudProgressService.shared.getCloudProgress(for: book)
    }

    func manualSync() async {
        await CloudProgressService.shared.refreshFromCloud()
        _ = await runRecentlyPlayedSync(trigger: .homePullToRefresh)
        _ = await KOReaderSyncService.shared.pullAllAndMerge()
        await flushPendingSyncs()
    }

    func resolveEbookConflict(bookStableId: String, useServer: Bool) {
        guard let conflict = EbookConflictStore.shared.remove(stableId: bookStableId) else { return }

        if let book = AppState.shared.bookInMemory(stableId: bookStableId) {
            RemoteRewindTracker.shared.recordUserResolution(
                scope: RemoteProgressScope(book: book, domain: .ebook, source: conflict.remoteSource),
                acceptedRemote: useServer
            )
        }

        if useServer {
            let updated = AppState.shared.mutateBook(stableId: bookStableId) { book in
                book.ebookProgress = conflict.serverProgress
                if let locator = conflict.serverLocator, !locator.isEmpty {
                    book.epubLocator = locator
                }
                book.lastUpdate = conflict.serverDate
            }
            if updated != nil {
                EbookLinkStore.shared.saveLinks()
                AppState.shared.allBooksChanged.send(())
            }
            return
        }

        guard var book = AppState.shared.bookInMemory(stableId: bookStableId) else { return }
        book.lastUpdate = Date()
        let resolvedBook = book
        Task {
            await pushProgress(book: resolvedBook, forceImmediate: true, domain: .ebook)
        }
    }

    func pullOnOpen(
        book: Book,
        domain: ProgressSyncDomain,
        excludingProvider: Bool = false
    ) async {
        guard syncEnabled else { return }
        let bookId = book.stableId

        emit(.pullStarted(bookId: bookId))

        if book.isStorytellerReadAloud && domain.usesEbookProgress {
            do {
                guard !excludingProvider,
                    let sink = PluginRegistry.shared.sinks(applicableTo: book, domain: domain)
                        .first(where: { $0.id == ProviderSyncSink.identifier }),
                    let snapshot = try await sink.pull(book: book, domain: domain)
                else {
                    emit(.pullCompleted(bookId: bookId, applied: false))
                    return
                }
                await applySnapshot(snapshot, to: book, usesEbookProgress: true)
                emit(.pullCompleted(bookId: bookId, applied: true))
            } catch {
                emit(.pullFailed(bookId: bookId, error: error.localizedDescription))
            }
            return
        }

        let sinks = PluginRegistry.shared.sinks(applicableTo: book, domain: domain).filter {
            !excludingProvider || $0.id != ProviderSyncSink.identifier
        }
        var snapshots: [SyncSnapshot] = []
        for sink in sinks {
            do {
                if let snap = try await sink.pull(book: book, domain: domain) {
                    snapshots.append(snap)
                }
            } catch {
                emit(.pullFailed(bookId: bookId, error: error.localizedDescription))
                return
            }
        }

        guard let snapshot = pickFreshest(snapshots) else {
            emit(.pullCompleted(bookId: bookId, applied: false))
            return
        }

        let localProgress: Double
        let localDate: Date
        let usesEbookProgress = domain.usesEbookProgress
        if usesEbookProgress {
            localProgress = book.canonicalEbookProgress
            localDate = book.lastUpdate
        } else {
            let savedPos = BookProgressStore.shared.loadProgress(for: book)?.progress ?? 0
            let dur = book.duration ?? 1
            localProgress = dur > 0 ? savedPos / dur : 0
            localDate = book.lastUpdate
        }

        let direction = resolveProgressConflictWithBackwardCheck(
            localPosition: localProgress,
            localDate: localDate,
            serverPosition: snapshot.progress,
            serverDate: snapshot.lastUpdate,
            localLocator: usesEbookProgress ? book.epubLocator : nil,
            serverLocator: usesEbookProgress ? snapshot.locator : nil
        )
        AppLogger.sync.info(
            "[SyncCoordinator] pullOnOpen local=\(Int(localProgress * 100))%@\(localDate.ISO8601Format()) \(snapshot.source)=\(Int(snapshot.progress * 100))%@\(snapshot.lastUpdate.ISO8601Format()) direction=\(direction) bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
        )

        switch direction {
        case .pull:
            AppLogger.sync.info(
                "[SyncCoordinator] Pulling \(snapshot.source) progress (\(Int(snapshot.progress * 100))%) for bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            await applySnapshot(snapshot, to: book, usesEbookProgress: usesEbookProgress)
            emit(.pullCompleted(bookId: bookId, applied: true))
        case .push:
            AppLogger.sync.info(
                "[SyncCoordinator] Local newer, pushing (\(Int(localProgress * 100))%) for bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            emit(.pullCompleted(bookId: bookId, applied: false))
            await pushProgress(book: book, forceImmediate: true, domain: domain)
        case .conflict:
            let verdict = RemoteRewindTracker.shared.assess(
                scope: RemoteProgressScope(book: book, domain: domain, source: snapshot.source),
                observation: RemoteProgressObservation(
                    progress: snapshot.progress,
                    positionSeconds: snapshot.positionSeconds > 0 ? snapshot.positionSeconds : nil,
                    locator: snapshot.locator,
                    observedAt: snapshot.lastUpdate
                ),
                localProgress: localProgress
            )

            switch verdict {
            case .confirmed:
                EbookConflictStore.shared.remove(stableId: bookId)
                AppLogger.sync.info(
                    "[SyncCoordinator] Confirmed intentional \(snapshot.source) rewind for bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                )
                await applySnapshot(snapshot, to: book, usesEbookProgress: usesEbookProgress)
                emit(.pullCompleted(bookId: bookId, applied: true))
            case .echo, .dismissed:
                emit(.pullCompleted(bookId: bookId, applied: false))
            case .notRewind, .unconfirmed:
                AppLogger.sync.info(
                    "[SyncCoordinator] Conflict detected for bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                )
                EbookConflictStore.shared.add(
                    EbookSyncConflict(
                        bookStableId: bookId,
                        bookTitle: book.title,
                        localProgress: localProgress,
                        serverProgress: snapshot.progress,
                        serverLocator: snapshot.locator,
                        serverDate: snapshot.lastUpdate,
                        remoteSource: snapshot.source
                    )
                )
                emit(
                    .conflictDetected(
                        bookId: bookId,
                        localProgress: localProgress,
                        remoteProgress: snapshot.progress,
                        remoteSource: snapshot.source
                    )
                )
                emit(.pullCompleted(bookId: bookId, applied: false))
            }
        case .none:
            emit(.pullCompleted(bookId: bookId, applied: false))
        }
    }

    func pushProgress(
        book: Book,
        forceImmediate: Bool = false,
        sourceEngine: ReaderEngineKind? = nil,
        domain: ProgressSyncDomain
    ) async {
        let bookId = book.stableId

        if forceImmediate {
            pushDebounceTasks.removeValue(forKey: bookId)?.cancel()
            await performPush(book: book, sourceEngine: sourceEngine, domain: domain)
            return
        }

        pushDebounceTasks[bookId]?.cancel()
        let capturedBook = book
        pushDebounceTasks[bookId] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.performPush(
                book: capturedBook,
                sourceEngine: sourceEngine,
                domain: domain
            )
        }
    }

    func pushCloudProgress(_ update: ProgressUpdate) async {
        guard syncEnabled else { return }
        if update.domain == .ebook,
            EbookConflictStore.shared.contains(stableId: update.book.stableId)
        {
            return
        }

        await serialQueue.enqueue(bookId: update.book.stableId) {
            do {
                try await CloudKitProgressSync.shared.push(update)
            } catch {
                AppLogger.sync.error(
                    "iCloud push failed for bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: update.book.stableId)): \(error.localizedDescription)"
                )
            }
        }
    }

    func pushAudiobookProgress(
        book: Book,
        position: TimeInterval,
        sessionId: String?,
        isFinished: Bool,
        timeListened: TimeInterval,
        forceImmediate: Bool = false
    ) async {
        let duration = book.duration ?? 0
        let update = ProgressUpdate(
            book: book,
            domain: .audiobook,
            positionSeconds: position,
            progress: duration > 0 ? position / duration : 0,
            locator: nil,
            sourceEngine: nil,
            sessionId: sessionId,
            isFinished: isFinished,
            timeListened: timeListened,
            playbackRate: ActivePlayback.controller.snapshot.playbackSpeed
        )

        if forceImmediate {
            await performPush(update: update)
            return
        }

        pushDebounceTasks[book.stableId]?.cancel()
        pushDebounceTasks[book.stableId] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.performPush(update: update)
        }
    }

    func pushFinished(
        book: Book,
        domain: ProgressSyncDomain
    ) async {
        await performPush(book: book, isFinished: true, domain: domain)
    }

    @discardableResult
    func persistCurrentPlayback(reason: ProgressSaveReason) async -> Bool {
        await CurrentPlaybackPersister.shared.saveCurrent(reason: reason)
    }

    func persistCurrentPlayback(book: Book, position: TimeInterval) async {
        await CurrentPlaybackPersister.shared.save(
            for: book,
            position: position,
            playbackRate: ActivePlayback.controller.snapshot.playbackSpeed
        )
    }

    @discardableResult
    func persistCurrentPlayback(
        book: Book,
        position: TimeInterval,
        playbackRate: Double,
        isFinished: Bool
    ) async -> Bool {
        guard syncEnabled else { return false }
        guard let sink = PluginRegistry.shared
            .sinks(applicableTo: book, domain: .audiobook)
            .first(where: { $0.id == CloudKitProgressSync.shared.id })
        else {
            return false
        }

        let duration = book.duration ?? 0
        let update = ProgressUpdate(
            book: book,
            domain: .audiobook,
            positionSeconds: position,
            progress: duration > 0 ? position / duration : 0,
            locator: nil,
            sourceEngine: nil,
            sessionId: nil,
            isFinished: isFinished,
            timeListened: 0,
            playbackRate: playbackRate
        )

        var succeeded = false
        await serialQueue.enqueue(bookId: book.stableId) {
            do {
                try await sink.push(update)
                succeeded = true
            } catch {
                AppLogger.sync.error(
                    "[SyncCoordinator] Current playback save failed for bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
                )
            }
        }
        return succeeded
    }

    func pushHardcoverIfNeeded(book: Book, progress: Double, sessionService: PlayerSessionService) async {
        let bookId = book.stableId
        let last = lastHardcoverProgress[bookId] ?? -1
        let isFinishing = progress >= Book.finishedProgressThreshold
        guard abs(progress - last) >= hardcoverThreshold || isFinishing else { return }
        lastHardcoverProgress[bookId] = progress
        if isFinishing {
            await HardcoverSyncService.shared.syncBookFinished(book: book)
        } else {
            await sessionService.syncHardcoverProgress(book: book, progress: progress)
        }
    }

    func subscribe(book: Book) -> AsyncStream<SyncEvent> {
        let bookId = book.stableId
        return AsyncStream { [weak self] continuation in
            Task { @MainActor [weak self] in
                self?.eventContinuations[bookId]?.finish()
                self?.eventContinuations[bookId] = continuation
                continuation.onTermination = { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.eventContinuations.removeValue(forKey: bookId)
                    }
                }
            }
        }
    }

    private func emit(_ event: SyncEvent) {
        let bookId: String
        switch event {
        case .pullStarted(let id), .pullCompleted(let id, _), .pullFailed(let id, _),
            .pushStarted(let id), .pushCompleted(let id), .pushFailed(let id, _, _),
            .conflictDetected(let id, _, _, _):
            bookId = id
        }
        eventContinuations[bookId]?.yield(event)
    }

    private func pickFreshest(_ snapshots: [SyncSnapshot]) -> SyncSnapshot? {
        guard let first = snapshots.first else { return nil }
        if snapshots.count == 1 { return first }
        let dates = snapshots.map { $0.lastUpdate }
        let span = (dates.max() ?? Date()).timeIntervalSince(dates.min() ?? Date())
        if span < 2 {
            return snapshots.max { $0.progress < $1.progress }
        }
        return snapshots.max { $0.lastUpdate < $1.lastUpdate }
    }

    func applySnapshot(
        _ snapshot: SyncSnapshot,
        to book: Book,
        usesEbookProgress: Bool
    ) async {
        guard AppState.shared.indexInMemory(stableId: book.stableId) != nil else { return }
        if usesEbookProgress {
            var resolvedLocator: String? = nil
            if let loc = snapshot.locator, !loc.isEmpty {
                if loc.hasPrefix("/body/DocFragment") {
                    let fileURL = EbookChapterSyncService.shared.resolvedFileURL(for: book)
                    if let url = fileURL,
                        let locatorJSON = await KOReaderXPointerConverter.locatorJSON(
                            xpointer: loc,
                            percentage: snapshot.progress,
                            epubFileURL: url
                        )
                    {
                        resolvedLocator = locatorJSON
                    }
                } else {
                    resolvedLocator = loc
                }
            }
            let narratedAudioTime = EpubLocationBridge.narratedAudioTime(from: resolvedLocator)
            let updatedBook = AppState.shared.mutateBook(stableId: book.stableId) { updated in
                updated.ebookProgress = snapshot.progress
                if let narratedAudioTime {
                    updated.currentTime = narratedAudioTime
                }
                updated.isFinished = snapshot.isFinished || snapshot.progress >= Book.finishedProgressThreshold
                updated.serverReadStatus = updated.isFinished ? "READ" : nil
                if let loc = resolvedLocator {
                    updated.epubLocator = loc
                } else if snapshot.progress <= 0.001 || book.source == .booklore {
                    updated.epubLocator = nil
                }
                updated.lastUpdate = snapshot.lastUpdate
            }
            EbookLinkStore.shared.saveLinks()
            if let updatedBook {
                if let narratedAudioTime {
                    NarratedAudioPositionStore.shared.recordNarration(
                        audioTime: narratedAudioTime,
                        for: updatedBook
                    )
                }
                await AppState.shared.bookStore.applyAuthoritativeProgress([
                    AuthoritativeProgressUpdate(
                        bookUniqueId: updatedBook.uniqueId,
                        stableId: updatedBook.stableId,
                        currentTime: updatedBook.currentTime,
                        duration: updatedBook.duration ?? 0,
                        ebookProgress: snapshot.progress,
                        epubLocator: updatedBook.epubLocator,
                        isFinished: updatedBook.isFinished,
                        lastUpdate: snapshot.lastUpdate,
                        hideFromContinue: updatedBook.hideFromContinue,
                        serverReadStatus: updatedBook.serverReadStatus
                    )
                ])
                await LinkedBookProgressCoordinator.shared.recordEbookProgress(
                    book: updatedBook,
                    progression: snapshot.progress,
                    observedAt: snapshot.lastUpdate,
                    authoritative: true
                )
            }
        } else {
            let duration = book.duration ?? 0
            let position =
                snapshot.positionSeconds > 0
                ? snapshot.positionSeconds
                : snapshot.progress * duration
            if duration > 0 || position > 0 {
                BookProgressStore.shared.saveProgress(
                    for: book,
                    progress: position,
                    duration: duration,
                    at: snapshot.lastUpdate
                )
            }
            let updatedBook = AppState.shared.mutateBook(stableId: book.stableId) {
                $0.currentTime = position
                $0.isFinished = snapshot.isFinished
                $0.serverReadStatus = snapshot.isFinished ? "READ" : nil
                $0.lastUpdate = snapshot.lastUpdate
            }
            if let updatedBook {
                await AppState.shared.bookStore.applyAuthoritativeProgress([
                    AuthoritativeProgressUpdate(
                        bookUniqueId: updatedBook.uniqueId,
                        stableId: updatedBook.stableId,
                        currentTime: position,
                        duration: duration,
                        ebookProgress: updatedBook.ebookProgress,
                        epubLocator: updatedBook.epubLocator,
                        isFinished: snapshot.isFinished,
                        lastUpdate: snapshot.lastUpdate,
                        hideFromContinue: updatedBook.hideFromContinue,
                        serverReadStatus: updatedBook.serverReadStatus
                    )
                ])
                await LinkedBookProgressCoordinator.shared.recordAudiobookProgress(
                    book: updatedBook,
                    currentTime: position,
                    isFinished: snapshot.isFinished,
                    observedAt: snapshot.lastUpdate,
                    authoritative: true
                )
            }
        }
    }

    private func performPush(
        book: Book,
        isFinished: Bool = false,
        sourceEngine: ReaderEngineKind? = nil,
        domain: ProgressSyncDomain
    ) async {
        let pushBook: Book
        if domain.usesEbookProgress {
            let cached =
                AppState.shared.bookInMemory(uniqueId: book.uniqueId)
                ?? AppState.shared.bookInMemory(stableId: book.stableId)
            pushBook = freshestEbookProgressBook(captured: book, cached: cached)
        } else {
            pushBook = book
        }
        await performPush(
            update: buildProgressUpdate(
                book: pushBook,
                isFinished: isFinished,
                sourceEngine: sourceEngine,
                domain: domain
            )
        )
    }

    private func performPush(update: ProgressUpdate) async {
        let book = update.book
        let bookId = book.stableId
        guard syncEnabled else { return }
        // Until the user picks a side, pushing would overwrite the position they may still choose.
        if update.domain.usesEbookProgress, EbookConflictStore.shared.contains(stableId: bookId) { return }

        let sinks = PluginRegistry.shared.sinks(applicableTo: book, domain: update.domain)
        let providerSink = sinks.first { $0.id == ProviderSyncSink.identifier }
        let hasProviderSync = providerSink != nil

        if hasProviderSync {
            emit(.pushStarted(bookId: bookId))
        }

        await serialQueue.enqueue(bookId: bookId) { [weak self] in
            guard let self else { return }
            var providerSucceeded = false
            var providerError: Error?
            var anySinkSucceeded = false

            for sink in sinks {
                do {
                    try await sink.push(update)
                    anySinkSucceeded = true
                    if sink.id == ProviderSyncSink.identifier {
                        providerSucceeded = true
                    }
                } catch {
                    if sink.id == ProviderSyncSink.identifier {
                        providerError = error
                    } else {
                        AppLogger.sync.error(
                            "[SyncCoordinator] Sink '\(sink.id)' push failed for bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
                        )
                    }
                }
            }

            if anySinkSucceeded {
                RemoteRewindTracker.shared.recordOutboundWrite(
                    key: RemoteProgressWriteKey(book: book, domain: update.domain),
                    progress: update.progress,
                    positionSeconds: update.positionSeconds > 0 ? update.positionSeconds : nil,
                    locator: update.locator
                )
            }

            if let providerError {
                let nsErr = providerError as NSError
                let retryable = nsErr.domain == NSURLErrorDomain
                AppLogger.sync.error(
                    "[SyncCoordinator] Push failed for bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(providerError.localizedDescription)"
                )
                self.emit(.pushFailed(bookId: bookId, error: providerError.localizedDescription, retryable: retryable))
                self.enqueuePendingSync(
                    book: book,
                    position: update.positionSeconds,
                    duration: book.duration ?? 0,
                    serverItemId: book.partKey ?? book.id,
                    domain: update.domain,
                    progress: update.progress,
                    locator: update.locator,
                    isFinished: update.isFinished
                )
            } else if hasProviderSync && providerSucceeded {
                AppLogger.sync.debug(
                    "[SyncCoordinator] Pushed progress for bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                )
                self.emit(.pushCompleted(bookId: bookId))
            } else if !hasProviderSync && update.isFinished {
                self.emit(.pushCompleted(bookId: bookId))
            }
        }
    }

    private func buildProgressUpdate(
        book: Book,
        isFinished: Bool,
        sourceEngine: ReaderEngineKind?,
        domain: ProgressSyncDomain
    ) -> ProgressUpdate {
        if domain.usesEbookProgress {
            return ProgressUpdate(
                book: book,
                domain: .ebook,
                positionSeconds: 0,
                progress: book.ebookProgress ?? book.canonicalEbookProgress,
                locator: book.epubLocator,
                sourceEngine: sourceEngine
                    ?? EpubLocationBridge.sourceEngine(from: book.epubLocator),
                sessionId: nil,
                isFinished: isFinished,
                timeListened: 0,
                playbackRate: ActivePlayback.controller.snapshot.playbackSpeed
            )
        }
        let position = BookProgressStore.shared.loadProgress(for: book)?.progress ?? 0
        let duration = book.duration ?? 0
        let progress = duration > 0 ? position / duration : 0
        let finished = isFinished || (duration > 0 && position >= duration * Book.finishedProgressThreshold)
        return ProgressUpdate(
            book: book,
            domain: .audiobook,
            positionSeconds: position,
            progress: progress,
            locator: nil,
            sourceEngine: nil,
            sessionId: nil,
            isFinished: finished,
            timeListened: 0,
            playbackRate: ActivePlayback.controller.snapshot.playbackSpeed
        )
    }
}

extension SyncCoordinator {
    nonisolated func pullOnOpenDetached(
        book: Book,
        domain: ProgressSyncDomain
    ) {
        Task { @MainActor in
            await SyncCoordinator.shared.pullOnOpen(book: book, domain: domain)
        }
    }
}
