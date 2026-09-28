import CloudKit
import Combine
import Foundation
import Logging

func resolveCloudProgressConflict(
    localPosition: Double,
    localDate: Date,
    cloudPosition: Double,
    cloudDate: Date,
    localLocator: String? = nil,
    cloudLocator: String? = nil
) -> SyncDirection {
    if cloudPosition <= 0, cloudDate > localDate { return .pull }
    return resolveProgressConflictWithBackwardCheck(
        localPosition: localPosition,
        localDate: localDate,
        serverPosition: cloudPosition,
        serverDate: cloudDate,
        localLocator: localLocator,
        serverLocator: cloudLocator
    )
}

enum CloudAudiobookMergeDisposition: Equatable {
    case apply
    case applyAndSeek
    case deferWhilePlaying
}

func cloudAudiobookMergeDisposition(isCurrentBook: Bool, isPlaying: Bool) -> CloudAudiobookMergeDisposition {
    guard isCurrentBook else { return .apply }
    return isPlaying ? .deferWhilePlaying : .applyAndSeek
}

func shouldDeferCloudMerge(
    domain: ProgressSyncDomain,
    isCurrentBook: Bool,
    isOverlayPlaybackActive: Bool,
    isPlaying: Bool
) -> Bool {
    domain == .ebook && isCurrentBook && isOverlayPlaybackActive && isPlaying
}

@MainActor
final class CloudProgressService {
    static let shared = CloudProgressService()
    private var pushSubscriptionRegistered = false

    private let cloudKit = CloudKitProgressSync.shared
    private let matchingService = BookMatchingService.shared
    private let playbackState: any PlaybackControlling = ActivePlayback.controller

    private var cancellables = Set<AnyCancellable>()
    private var cloudSyncTask: Task<Void, Never>?
    private var cloudMergeTask: Task<Void, Never>?

    private let libraryCache: LibraryBookCache
    private let connectionStore: ProviderConnectionStore
    private let bookRepository: BookStoreRepository

    private init(
        libraryCache: LibraryBookCache = AppState.shared.libraryCache,
        connectionStore: ProviderConnectionStore = AppState.shared.providerConnections,
        bookRepository: BookStoreRepository = AppState.shared.bookStore
    ) {
        self.libraryCache = libraryCache
        self.connectionStore = connectionStore
        self.bookRepository = bookRepository
        setupNotificationObservers()
        checkCloudKitAvailability()
    }

    private func checkCloudKitAvailability() {
        Task {
            AppLogger.sync.info("Checking CloudKit availability...")
            let available = await cloudKit.isAvailable()
            SyncCoordinator.shared.updateCloudAvailability(available)
            if !available {
                AppLogger.sync.info("CloudKit not available - sync will be skipped")
                return
            }
            AppLogger.sync.info("CloudKit is available")
            if !pushSubscriptionRegistered {
                await cloudKit.registerForPushNotifications()
                pushSubscriptionRegistered = cloudKit.pushSubscriptionRegistered
            }
        }
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.publisher(for: .cloudKitProgressDidChange)
            .sink { [weak self] notification in
                Task { @MainActor in
                    await self?.handleCloudProgressUpdate(notification)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .serverProgressUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                Task { @MainActor in
                    await self?.applyServerProgressUpdate(notification)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                AppLogger.sync.info("CKAccountChanged - re-checking CloudKit availability")
                cloudKit.invalidateAccountStatusCache()
                pushSubscriptionRegistered = false
                checkCloudKitAvailability()
            }
            .store(in: &cancellables)

    }

    @MainActor
    private func applyServerProgressUpdate(_ notification: Notification) async {
        guard let info = notification.userInfo,
            let bookId = info["bookId"] as? String
        else { return }

        let serverProgress = (info["progress"] as? Double) ?? 0
        let serverLocator = info["locatorJSON"] as? String
        let serverTimestamp = (info["timestamp"] as? Int).map { TimeInterval($0) / 1000.0 } ?? TimeInterval(0)
        let serverDate = Date(timeIntervalSince1970: serverTimestamp)
        let providerId = info["providerId"] as? UUID
        let diagnosticBookID = DiagnosticLogSanitizer.identifier(for: bookId)

        let lookup: Book?
        if let providerId,
            let book = self.libraryCache.bookInMemory(uniqueId: "\(providerId)_\(bookId)")
        {
            lookup = book
        } else if let providerId,
            let book = await self.bookRepository.book(uniqueId: "\(providerId)_\(bookId)")
        {
            lookup = book
        } else if let book = self.libraryCache.bookInMemory(uniqueId: bookId) {
            lookup = book
        } else if let book = self.libraryCache.bookInMemory(stableId: bookId) {
            lookup = book
        } else {
            lookup = await self.bookRepository.book(byBookId: bookId)
        }
        guard let current = lookup,
            providerId == nil || current.providerId == providerId
        else { return }
        let localDate = current.lastUpdate

        guard serverDate >= localDate else {
            AppLogger.sync.info(
                "serverProgressUpdated: ignored stale timestamp bookDiagnosticID=\(diagnosticBookID)"
            )
            return
        }

        if info["progressDomain"] as? String == "audiobook" {
            guard let position = info["positionSeconds"] as? TimeInterval else {
                AppLogger.sync.warning(
                    "serverProgressUpdated: missing Storyteller audiobook position bookDiagnosticID=\(diagnosticBookID)"
                )
                return
            }
            let duration = current.duration ?? 0
            BookProgressStore.shared.saveProgress(
                for: current,
                progress: position,
                duration: duration,
                at: serverDate
            )
            let updated = self.libraryCache.mutateBook(uniqueId: current.uniqueId) { book in
                book.currentTime = position
                book.isFinished = duration > 0 && position >= duration * Book.finishedProgressThreshold
                book.lastUpdate = serverDate
            }
            if let updated {
                await self.bookRepository.updateProgress(
                    uniqueId: updated.uniqueId,
                    currentTime: position,
                    isFinished: updated.isFinished,
                    lastUpdate: serverDate
                )
            }
            let playback = ActivePlayback.controller
            if !playback.snapshot.isOverlayPlaybackActive,
                playback.snapshot.currentBook?.uniqueId == current.uniqueId
            {
                playback.seek(to: position)
            }
            AppLogger.sync.debug(
                "serverProgressUpdated: applied Storyteller positionSeconds=\(Int(position)) bookDiagnosticID=\(diagnosticBookID)"
            )
            return
        }

        let mutateKey =
            self.libraryCache.indexInMemory(uniqueId: current.uniqueId) != nil
            ? current.uniqueId : current.stableId
        if self.libraryCache.indexInMemory(uniqueId: mutateKey) != nil {
            self.libraryCache.mutateBook(uniqueId: mutateKey) { book in
                book.ebookProgress = serverProgress
                if let loc = serverLocator, !loc.isEmpty { book.epubLocator = loc }
                book.lastUpdate = serverDate
            }
        } else {
            self.libraryCache.mutateBook(stableId: mutateKey) { book in
                book.ebookProgress = serverProgress
                if let loc = serverLocator, !loc.isEmpty { book.epubLocator = loc }
                book.lastUpdate = serverDate
            }
        }
        EbookLinkStore.shared.saveLinks()
        AppLogger.sync.debug(
            "serverProgressUpdated: applied progress=\(Int(serverProgress * 100))% bookDiagnosticID=\(diagnosticBookID)"
        )
    }

    func refreshFromCloud() async {
        let coordinator = SyncCoordinator.shared
        guard coordinator.syncEnabled else { return }
        guard !coordinator.isSyncing else { return }

        coordinator.beginSync()
        defer { coordinator.endSync(at: nil) }

        AppLogger.sync.info("Refreshing from cloud...")

        cloudKit.invalidateCache()

        do {
            let records = try await cloudKit.fetchAllRecords()
            AppLogger.sync.info("Fetched \(records.count) cloud records")
            await mergeCloudRecords(records, books: libraryCache.books)

            if let mostRecent = records.max(by: { $0.lastUpdated < $1.lastUpdated }) {
                coordinator.updateLastSync(
                    date: mostRecent.lastUpdated,
                    deviceName: mostRecent.deviceName
                )
                AppLogger.sync.debug("Updated latest CloudKit activity metadata")
            }

        } catch {
            AppLogger.sync.error("Failed to refresh from cloud: \(error)")
        }
    }

    func refreshCurrentBookFromServer() async {
        let playerVM = playbackState
        guard let book = await MainActor.run(body: { playerVM.currentBook }) else { return }
        let isCurrentlyPlaying = await MainActor.run { playerVM.isPlaying }
        guard !isCurrentlyPlaying else { return }

        guard !book.isReadAloudBook else { return }

        let isServerSource =
            book.source == .audiobookshelf
            || book.source == .jellyfin
            || book.source == .emby
        guard isServerSource,
            let backendId = book.backendId,
            let backend = await MainActor.run(body: {
                self.connectionStore.backend(id: backendId)
            })
        else { return }

        do {
            let absService = AudiobookshelfService.shared
            guard
                let serverProgress = try await absService.getProgress(
                    libraryItemId: book.partKey ?? book.id,
                    backend: backend
                )
            else { return }

            let serverTime = serverProgress.currentTime ?? 0
            let serverDate = serverProgress.lastUpdate.flatMap { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
            let localTime = await MainActor.run { playerVM.progress }
            let localProgressData = BookProgressStore.shared.loadProgress(for: book)
            let localDate = localProgressData.flatMap { Date(timeIntervalSince1970: $0.lastUpdated) } ?? .distantPast
            let duration = serverProgress.duration ?? book.duration ?? 0

            let direction = resolveProgressConflict(
                localPosition: localTime,
                localDate: localDate,
                serverPosition: serverTime,
                serverDate: serverDate
            )

            switch direction {
            case .pull:
                AppLogger.sync.info("Foreground: server is newer (\(Int(serverTime))s vs local \(Int(localTime))s)")
                BookProgressStore.shared.saveProgress(for: book, progress: serverTime, duration: duration)
                playbackState.seek(to: serverTime)
            case .push:
                AppLogger.sync.info("Foreground: local is newer (\(Int(localTime))s vs server \(Int(serverTime))s) - pushing")
                let localDuration = localProgressData?.duration ?? duration
                do {
                    try await AudiobookshelfService.shared.updateProgress(
                        libraryItemId: book.partKey ?? book.id,
                        currentTime: localTime,
                        duration: localDuration,
                        isFinished: localDuration > 0 && localTime >= localDuration,
                        backend: backend
                    )
                } catch {
                    AppLogger.sync.error("Failed to push local progress on foreground: \(error.localizedDescription)")
                }
            case .none:
                break
            case .conflict:
                break
            }
        } catch {
            AppLogger.sync.error("Foreground server refresh failed: \(error.localizedDescription)")
        }
    }

    func syncOnAppLaunch(books: [Book]) async {
        await syncBooksFromCloud(books, reason: "app launch")
    }

    func syncNewBooksFromCloud(_ books: [Book]) async {
        await syncBooksFromCloud(books, reason: "library addition")
    }

    private func syncBooksFromCloud(_ books: [Book], reason: String) async {
        let previousTask = cloudSyncTask
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            await self?.performCloudSync(books, reason: reason)
        }
        cloudSyncTask = task
        await task.value
    }

    private func performCloudSync(_ books: [Book], reason: String) async {
        let coordinator = SyncCoordinator.shared
        guard coordinator.syncEnabled else {
            AppLogger.sync.warning("Sync disabled, skipping iCloud \(reason) sync")
            return
        }

        let candidates = books.filter(CloudProgressEligibility.includes)
        guard !candidates.isEmpty else { return }

        let ownsSyncState = !coordinator.isSyncing
        if ownsSyncState { coordinator.beginSync() }
        defer {
            if ownsSyncState { coordinator.endSync(at: nil) }
        }

        AppLogger.sync.info("Starting iCloud \(reason) sync with \(candidates.count) books...")

        let cloudAvailable = await cloudKit.isAvailable()
        coordinator.updateCloudAvailability(cloudAvailable)
        guard cloudAvailable else {
            AppLogger.sync.info("CloudKit not available")
            return
        }

        do {
            let records = try await cloudKit.fetchAllRecords(bypassCache: true)
            await mergeCloudRecords(records, books: candidates)
        } catch {
            AppLogger.sync.error("iCloud \(reason) sync failed: \(error.localizedDescription)")
        }

        coordinator.updateLastSync(date: Date())
    }

    func getCloudProgress(for book: Book) async -> (position: TimeInterval, deviceName: String?)? {
        guard book.mediaType == .audiobook, CloudProgressEligibility.includes(book) else { return nil }
        let coordinator = SyncCoordinator.shared
        guard coordinator.syncEnabled, coordinator.isCloudKitAvailable else { return nil }

        if let record = await matchingService.findCloudProgress(for: book) {
            return (record.playbackPosition, record.deviceName)
        }

        return nil
    }

    private func handleCloudProgressUpdate(_ notification: Notification) async {
        guard SyncCoordinator.shared.syncEnabled else { return }
        guard let records = notification.userInfo?["records"] as? [PlaybackStateRecord] else { return }
        await mergeCloudRecords(records, books: libraryCache.books)
        SyncCoordinator.shared.updateLastSync(date: Date())
    }

    private func mergeCloudRecords(_ records: [PlaybackStateRecord], books: [Book]) async {
        let candidateStableIds = Set(
            books.lazy.filter(CloudProgressEligibility.includes).map(\.stableId)
        )
        guard !candidateStableIds.isEmpty else { return }

        let previousTask = cloudMergeTask
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            await self?.mergeCloudRecordBatch(
                records,
                candidateStableIds: candidateStableIds
            )
        }
        cloudMergeTask = task
        await task.value
    }

    private func mergeCloudRecordBatch(
        _ records: [PlaybackStateRecord],
        candidateStableIds: Set<String>
    ) async {
        let localBooks = libraryCache.books.filter {
            candidateStableIds.contains($0.stableId) && CloudProgressEligibility.includes($0)
        }
        let localContentHashes = CloudBookContentIdentity.hashes(for: localBooks)
        let indexedRecords = records.map { ($0, $0.toCanonicalIdentity()) }
        let recordsByDomainAndHash = Dictionary(
            grouping: records.compactMap { record -> (String, PlaybackStateRecord)? in
                guard let contentHash = record.contentHash else { return nil }
                return ("\(record.domain.rawValue)|\(contentHash)", record)
            },
            by: \.0
        )
        let recordsByDomainAndTitle = Dictionary(grouping: indexedRecords) {
            "\($0.0.domain.rawValue)|\($0.1.normalizedTitle)"
        }

        for book in localBooks {
            let domain: ProgressSyncDomain = book.mediaType == .ebook || book.isReadAloudBook ? .ebook : .audiobook
            if domain == .ebook, SyncCoordinator.shared.isEbookReaderOpen { continue }
            let localIdentity = CanonicalBookIdentity(from: book)
            let lookupKey = "\(domain.rawValue)|\(localIdentity.normalizedTitle)"
            let hashCandidates: [PlaybackStateRecord] = if let contentHash = localContentHashes[book.stableId] {
                recordsByDomainAndHash["\(domain.rawValue)|\(contentHash)"]?.map(\.1) ?? []
            } else {
                []
            }
            let titleCandidates = (recordsByDomainAndTitle[lookupKey] ?? []).filter {
                if $0.0.recordID == CloudKitProgressSync.recordName(for: localIdentity, domain: domain) {
                    return true
                }
                let match = localIdentity.matches($0.1)
                return match == .exactMatch || match.confidence >= 0.7
            }.map(\.0)
            let candidates = hashCandidates.isEmpty ? titleCandidates : hashCandidates
            guard let record = candidates.max(by: { $0.lastUpdated < $1.lastUpdated }) else { continue }

            AppLogger.sync.debug("Received CloudKit playback update at \(Int(record.playbackPosition))s")

            let isCurrentBook = playbackState.currentBook?.stableId == book.stableId
            if shouldDeferCloudMerge(
                domain: record.domain,
                isCurrentBook: isCurrentBook,
                isOverlayPlaybackActive: playbackState.snapshot.isOverlayPlaybackActive,
                isPlaying: playbackState.isPlaying
            ) {
                AppLogger.sync.debug(
                    "Deferred CloudKit merge for active read-aloud bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                )
                continue
            }

            let playbackDisposition = cloudAudiobookMergeDisposition(
                isCurrentBook: record.domain == .audiobook && isCurrentBook,
                isPlaying: playbackState.isPlaying
            )
            if playbackDisposition == .deferWhilePlaying {
                AppLogger.sync.debug(
                    "Deferred CloudKit merge for actively playing bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                )
                continue
            }

            let savedAudiobookProgress = BookProgressStore.shared.loadProgress(for: book)
            let localPosition = record.domain == .ebook
                ? book.canonicalEbookProgress
                : savedAudiobookProgress?.progress ?? 0
            let localDate = record.domain == .ebook
                ? book.lastUpdate
                : savedAudiobookProgress.map { Date(timeIntervalSince1970: $0.lastUpdated) } ?? .distantPast
            let remotePosition = record.domain == .ebook
                ? record.normalizedProgress
                : record.playbackPosition

            let direction = resolveCloudProgressConflict(
                localPosition: localPosition,
                localDate: localDate,
                cloudPosition: remotePosition,
                cloudDate: record.lastUpdated,
                localLocator: record.domain == .ebook ? book.epubLocator : nil,
                cloudLocator: record.domain == .ebook ? record.locator : nil
            )

            switch direction {
            case .pull:
                AppLogger.sync.debug(
                    "Pulling iCloud progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                )
                await SyncCoordinator.shared.applySnapshot(
                    SyncSnapshot(
                        progress: record.normalizedProgress,
                        positionSeconds: record.playbackPosition,
                        locator: record.locator,
                        lastUpdate: record.lastUpdated,
                        isFinished: record.completed,
                        source: "iCloud"
                    ),
                    to: book,
                    usesEbookProgress: record.domain == .ebook
                )
                if record.domain == .ebook,
                    isCurrentBook,
                    playbackState.snapshot.isOverlayPlaybackActive,
                    let position = EpubLocationBridge.narratedAudioTime(from: record.locator)
                {
                    playbackState.seek(to: position)
                }
                if playbackDisposition == .applyAndSeek {
                    let position = record.playbackPosition > 0
                        ? record.playbackPosition
                        : record.normalizedProgress * (book.duration ?? 0)
                    playbackState.seek(to: position)
                }
            case .push:
                AppLogger.sync.debug(
                    "Local progress newer than CloudKit bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                )
                await pushLocalProgressToCloud(book: book, domain: record.domain)
            case .conflict:
                if record.domain == .ebook {
                    EbookConflictStore.shared.add(
                        EbookSyncConflict(
                            bookStableId: book.stableId,
                            bookTitle: book.title,
                            localProgress: localPosition,
                            serverProgress: record.normalizedProgress,
                            serverLocator: record.locator,
                            serverDate: record.lastUpdated,
                            remoteSource: "iCloud"
                        )
                    )
                } else {
                    AppLogger.sync.warning(
                        "CloudKit progress conflict; kept local bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                    )
                }
            case .none:
                break
            }
        }

        NotificationCenter.default.post(name: .continueListeningNeedsRefresh, object: nil)
    }

    private func pushLocalProgressToCloud(book: Book, domain: ProgressSyncDomain) async {
        let position: TimeInterval
        let progress: Double
        if domain == .ebook {
            position = 0
            progress = book.canonicalEbookProgress
        } else {
            position = BookProgressStore.shared.loadProgress(for: book)?.progress ?? 0
            let duration = book.duration ?? 0
            progress = duration > 0 ? position / duration : 0
        }

        let update = ProgressUpdate(
            book: book,
            domain: domain,
            positionSeconds: position,
            progress: progress,
            locator: domain == .ebook ? book.epubLocator : nil,
            sourceEngine: domain == .ebook ? EpubLocationBridge.sourceEngine(from: book.epubLocator) : nil,
            sessionId: nil,
            isFinished: book.isFinished || progress >= Book.finishedProgressThreshold,
            timeListened: 0,
            playbackRate: ActivePlayback.controller.snapshot.playbackSpeed
        )

        await SyncCoordinator.shared.pushCloudProgress(update)
    }
}

extension Notification.Name {
    static let continueListeningNeedsRefresh = Notification.Name("continueListeningNeedsRefresh")
    static let libraryDidFinishSync = Notification.Name("libraryDidFinishSync")
}
