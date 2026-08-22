import CloudKit
import Combine
import Foundation
import Logging

@MainActor
final class CloudProgressService {
    static let shared = CloudProgressService()
    private var pushSubscriptionRegistered = false

    private let cloudKit = CloudKitProgressSync.shared
    private let matchingService = BookMatchingService.shared
    private let playbackState: any PlaybackControlling = ActivePlayback.controller

    private var cancellables = Set<AnyCancellable>()

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
                book.isFinished = duration > 0 && position >= duration * 0.99
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
        let coordinator = SyncCoordinator.shared
        guard coordinator.syncEnabled else {
            AppLogger.sync.warning("Sync disabled, skipping app launch sync")
            return
        }

        guard !coordinator.isSyncing else {
            AppLogger.sync.warning("Already syncing, skipping")
            return
        }

        coordinator.beginSync()
        defer { coordinator.endSync(at: nil) }

        let audiobooks = books.filter { $0.mediaType == .audiobook }
        AppLogger.sync.info("Starting app launch sync with \(audiobooks.count) audiobooks...")

        let cloudAvailable = await cloudKit.isAvailable()
        coordinator.updateCloudAvailability(cloudAvailable)
        guard cloudAvailable else {
            AppLogger.sync.info("CloudKit not available")
            return
        }

        let results = await matchingService.matchAndUpdateProgress(books: audiobooks, autoUpdate: true)

        if !results.isEmpty {
            AppLogger.sync.info("Found \(results.count) books with cloud progress (auto-updated locally)")

            NotificationCenter.default.post(
                name: .continueListeningNeedsRefresh,
                object: nil
            )
        }

        coordinator.updateLastSync(date: Date())
    }

    func getCloudProgress(for book: Book) async -> (position: TimeInterval, deviceName: String?)? {
        guard book.mediaType == .audiobook else { return nil }
        let coordinator = SyncCoordinator.shared
        guard coordinator.syncEnabled, coordinator.isCloudKitAvailable else { return nil }

        if let record = await matchingService.findCloudProgress(for: book) {
            return (record.playbackPosition, record.deviceName)
        }

        return nil
    }

    private func handleCloudProgressUpdate(_ notification: Notification) async {
        guard let records = notification.userInfo?["records"] as? [PlaybackStateRecord] else { return }

        let currentDeviceID = cloudKit.currentDeviceID

        for record in records {
            guard record.deviceID != currentDeviceID else { continue }

            AppLogger.sync.debug("Received CloudKit playback update at \(Int(record.playbackPosition))s")

            let cloudIdentity = record.toCanonicalIdentity()
            let localBooks = await MainActor.run {
                self.libraryCache.books.filter { $0.mediaType == .audiobook }
            }

            for book in localBooks {
                let localIdentity = CanonicalBookIdentity(from: book)
                let matchResult = localIdentity.matches(cloudIdentity)
                guard matchResult == .exactMatch || matchResult.isMatch else { continue }

                if playbackState.currentBook?.stableId == book.stableId {
                    AppLogger.sync.debug(
                        "Skipped CloudKit merge for current bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                    )
                    break
                }

                let localProgress = BookProgressStore.shared.loadProgress(for: book)
                let localPosition = localProgress?.progress ?? 0
                let localDate = localProgress.map { Date(timeIntervalSince1970: $0.lastUpdated) } ?? .distantPast

                let direction = resolveProgressConflictWithBackwardCheck(
                    localPosition: localPosition,
                    localDate: localDate,
                    serverPosition: record.playbackPosition,
                    serverDate: record.lastUpdated
                )

                switch direction {
                case .pull:
                    AppLogger.sync.debug(
                        "Pulling CloudKit progress bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) \(Int(localPosition))s -> \(Int(record.playbackPosition))s"
                    )
                    BookProgressStore.shared.saveProgress(
                        for: book,
                        progress: record.playbackPosition,
                        duration: TimeInterval(record.duration)
                    )
                case .push:
                    AppLogger.sync.debug(
                        "Local progress newer than CloudKit bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                    )
                case .conflict:
                    AppLogger.sync.warning(
                        "CloudKit progress conflict; kept local bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                    )
                case .none:
                    break
                }
                break
            }
        }

        SyncCoordinator.shared.updateLastSync(date: Date())
        NotificationCenter.default.post(name: .continueListeningNeedsRefresh, object: nil)
    }
}

extension Notification.Name {
    static let continueListeningNeedsRefresh = Notification.Name("continueListeningNeedsRefresh")
    static let libraryDidFinishSync = Notification.Name("libraryDidFinishSync")
}
