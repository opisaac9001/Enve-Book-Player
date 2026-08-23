#if os(tvOS)
import AVFoundation
import Combine
import Foundation
import Logging

@MainActor
final class TVBookPlaybackCoordinator: BookPlaybackStarting, RestoredPlaybackPreparing, PlaybackConflictResolving {
    private let controller: any PlaybackControlling
    private let loader: any PlaybackLoading
    private let preparationReporter: any PlaybackPreparationReporting
    private let failureReporter: any PlaybackFailureReporting
    private let streamResolver: PlayerStreamURLResolver
    private let chapterService: PlayerChapterService
    private let progressService: PlayerProgressService
    private let sessionService: PlayerSessionService
    private let bookmarkService: PlayerBookmarkService
    private let providerConnections: any ProviderConnectionAccessing
    private let bookQuerying: any BookQuerying
    private let libraryCache: any PlayerLibraryCaching

    private var activePlayToken = UUID()
    private var prewarmTask: Task<Void, Never>?
    private var resolvedGrimmoryTracks: [AudioTrack]?
    private var conflictedBook: Book?
    private let conflictSubject = CurrentValueSubject<PlaybackProgressConflict?, Never>(nil)

    init(
        controller: any PlaybackControlling,
        loader: any PlaybackLoading,
        preparationReporter: any PlaybackPreparationReporting,
        failureReporter: any PlaybackFailureReporting,
        streamResolver: PlayerStreamURLResolver = .shared,
        chapterService: PlayerChapterService = .shared,
        progressService: PlayerProgressService = .shared,
        sessionService: PlayerSessionService = .shared,
        bookmarkService: PlayerBookmarkService = PlayerBookmarkService(),
        providerConnections: any ProviderConnectionAccessing,
        bookQuerying: any BookQuerying,
        libraryCache: any PlayerLibraryCaching
    ) {
        self.controller = controller
        self.loader = loader
        self.preparationReporter = preparationReporter
        self.failureReporter = failureReporter
        self.streamResolver = streamResolver
        self.chapterService = chapterService
        self.progressService = progressService
        self.sessionService = sessionService
        self.bookmarkService = bookmarkService
        self.providerConnections = providerConnections
        self.bookQuerying = bookQuerying
        self.libraryCache = libraryCache

    }

    private func diagnosticBookID(_ book: Book) -> String {
        DiagnosticLogSanitizer.identifier(for: book.stableId)
    }

    // MARK: - BookPlaybackStarting

    func play(_ book: Book, presentPlayer: Bool) {
        Task { await start(book) }
    }

    func start(_ book: Book) async {
        prewarmTask?.cancel()
        prewarmTask = nil

        if controller.snapshot.currentBook?.id == book.id,
            controller.snapshot.isLoaded
        {
            controller.togglePlay()
            return
        }

        libraryCache.ensureBookInMemory(book)

        let playToken = UUID()
        await prepareForNewBook(playToken: playToken, newBook: book)

        resolvedGrimmoryTracks = nil

        do {
            try await loadAndStart(book, playToken: playToken)
            if activePlayToken == playToken {
                preparationReporter.endPreparation(errorDescription: nil)
            }
        } catch {
            guard activePlayToken == playToken else { return }
            preparationReporter.endPreparation(errorDescription: Self.startFailureDescription(for: error))
            failureReporter.reportPlaybackFailure(for: book)
        }
    }

    private func prepareForNewBook(playToken: UUID, newBook: Book) async {
        activePlayToken = playToken

        if let previousBook = controller.snapshot.currentBook, previousBook.id != newBook.id {
            progressService.saveProgress(
                book: previousBook,
                position: controller.snapshot.position,
                duration: controller.snapshot.duration
            )
            BookProgressStore.shared.saveRecentlyPlayed(previousBook)
            await sessionService.closeABSSession(
                progress: controller.snapshot.position,
                duration: controller.snapshot.duration
            )
            progressService.absSessionActive = false
        }

        preparationReporter.beginPreparation()
        streamResolver.cleanupSecurityScopedAccess()
        PlayerStateStore.shared.saveLastPlayedBookId(newBook.stableId)
    }

    private func loadAndStart(_ book: Book, playToken: UUID) async throws {
        await chapterService.loadChapters(for: book)
        let knownBookIds = await bookQuerying.allBookIds()
        ReaderDataMigration.recoverOrphanedFileShareBookmarks(for: book, knownBookIds: knownBookIds)
        await syncBookmarksFromABS(book: book)
        await syncBookOrbitBookmarks(book: book)

        guard activePlayToken == playToken else { return }

        guard let streamURL = try await streamResolver.streamURL(for: book) else {
            throw NSError(
                domain: "TVBookPlaybackCoordinator",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to get stream URL"]
            )
        }

        guard activePlayToken == playToken else { return }
        await enrichChaptersIfNeeded(for: book, streamURL: streamURL)

        guard activePlayToken == playToken else { return }

        let localPosition = progressService.loadProgress(for: book)?.position ?? 0
        let serverPosition = sessionService.lastServerCurrentTime ?? 0
        var startPosition: TimeInterval = max(localPosition, serverPosition)
        let bookDuration = book.duration ?? controller.snapshot.duration

        if startPosition < 1 {
            if let cloudProgress = await SyncCoordinator.shared.getCloudProgress(for: book) {
                if cloudProgress.position > 5 {
                    AppLogger.player.info("Using CloudKit position (\(Int(cloudProgress.position))s) - local and server were 0")
                    startPosition = cloudProgress.position
                    progressService.saveProgress(book: book, position: startPosition, duration: bookDuration)
                }
            }
        } else if serverPosition > localPosition + 5 {
            AppLogger.player.info("Using server position (\(Int(serverPosition))s) over local (\(Int(localPosition))s)")
            startPosition = serverPosition
            progressService.saveProgress(book: book, position: serverPosition, duration: bookDuration)
        }

        if let localFiles = LocalStorageManager.shared.localAudiobookFilesIfExists(for: book), !localFiles.isEmpty {
            if localFiles.count > 1 {
                let remoteTracks = (book.audioTracks ?? []).sorted { $0.index < $1.index }
                var runningOffset: TimeInterval = 0
                let localTracks: [AudioTrack] = localFiles.enumerated().map { index, fileURL in
                    let remoteTrack = index < remoteTracks.count ? remoteTracks[index] : nil
                    let duration = remoteTrack?.duration ?? 0
                    let track = AudioTrack(
                        index: index,
                        title: remoteTrack?.title ?? fileURL.deletingPathExtension().lastPathComponent,
                        filePath: fileURL.path,
                        contentUrl: nil,
                        duration: duration,
                        startOffset: runningOffset
                    )
                    runningOffset += duration
                    return track
                }
                AppLogger.player.info("Using \(localTracks.count) local downloaded tracks for playback")
                loader.loadTracks(localTracks, book: book, startingAt: startPosition)
            } else if let first = localFiles.first {
                AppLogger.player.debug(
                    "Using local downloaded file: \(DiagnosticLogSanitizer.fileDescriptor(for: first))"
                )
                loader.load(url: first, book: book, startingAt: startPosition)
            } else {
                loader.load(url: streamURL, book: book, startingAt: startPosition)
            }
        } else if let grimmoryTracks = resolvedGrimmoryTracks, grimmoryTracks.count > 1 {
            AppLogger.player.debug(
                "Streaming \(grimmoryTracks.count) Grimmory tracks for bookDiagnosticID=\(diagnosticBookID(book))"
            )
            loader.loadTracks(grimmoryTracks, book: book, startingAt: startPosition)
            resolvedGrimmoryTracks = nil
        } else if let audioTracks = book.audioTracks, audioTracks.count > 1 {
            loader.loadTracks(audioTracks, book: book, startingAt: startPosition)
        } else {
            loader.load(url: streamURL, book: book, startingAt: startPosition)
        }

        let absSessionResolved = sessionService.lastServerCurrentTime != nil
        await handleProgressConflicts(book: book, localProgress: startPosition, serverPositionAlreadyResolved: absSessionResolved)

        controller.setPlaybackRate(LibraryDisplayPreferencesStore.shared.loadPreferences().playbackSpeed)
        loader.setupNowPlaying(book: book)
        loader.updateNowPlayingInfo()
        controller.play()

        Task {
            await HardcoverAutoMatcher.shared.attemptAutoMatch(for: book)
            await HardcoverSyncService.shared.syncBookStarted(book: book)
        }

        SyncCoordinator.shared.pullOnOpenDetached(book: book, domain: .audiobook)

        clearStaleSleepTimerFireState(for: book)
    }

    private static func startFailureDescription(for error: Error) -> String {
        let nsError = error as NSError
        let isNetworkError =
            nsError.domain == NSURLErrorDomain
            || nsError.code == NSURLErrorNotConnectedToInternet
            || nsError.code == NSURLErrorNetworkConnectionLost
            || nsError.code == NSURLErrorTimedOut
        if isNetworkError {
            return "You're offline. Download this book to play it without an internet connection."
        }
        return error.localizedDescription
    }

    // MARK: - Progress conflicts

    var conflict: PlaybackProgressConflict? { conflictSubject.value }

    var conflicts: AnyPublisher<PlaybackProgressConflict?, Never> {
        conflictSubject.eraseToAnyPublisher()
    }

    func resolveConflict(useServer: Bool) {
        guard let conflict = conflictSubject.value, let book = conflictedBook else { return }
        if useServer {
            controller.seek(to: conflict.server)
            progressService.saveProgress(
                book: book,
                position: conflict.server,
                duration: book.duration ?? controller.snapshot.duration
            )
        } else {
            Task { await progressService.syncProgressToRemote(book: book, progress: conflict.local) }
        }
        controller.togglePlay()
        conflictedBook = nil
        conflictSubject.send(nil)
    }

    func dismissConflict() {
        conflictedBook = nil
        conflictSubject.send(nil)
    }

    private func handleProgressConflicts(
        book: Book,
        localProgress: TimeInterval,
        serverPositionAlreadyResolved: Bool
    ) async {
        guard LibraryDisplayPreferencesStore.shared.loadPreferences().autoSyncProgress else { return }

        guard let conflict = await progressService.checkProgressConflict(
            book: book,
            localProgress: localProgress,
            serverPositionAlreadyResolved: serverPositionAlreadyResolved
        ) else { return }

        if conflict.autoAcceptRemote {
            AppLogger.player.info("Auto-accepting remote progress: \(Int(conflict.remoteProgress))s from \(conflict.remoteName)")
            controller.seek(to: conflict.remoteProgress)
            progressService.saveProgress(
                book: book,
                position: conflict.remoteProgress,
                duration: book.duration ?? controller.snapshot.duration
            )
            return
        }

        conflictedBook = book
        conflictSubject.send(
            PlaybackProgressConflict(
                local: conflict.localProgress,
                server: conflict.remoteProgress,
                bookId: book.stableId
            )
        )
    }

    // MARK: - Remote bookmark sync

    private func syncBookmarksFromABS(book: Book) async {
        guard book.source == .audiobookshelf,
            let backendId = book.backendId,
            let backend = providerConnections.backend(id: backendId)
        else { return }
        let local = ReaderArtifactsStore.shared.loadBookmarks(bookId: book.stableId)
        let merged = await AudiobookshelfService.shared.syncBookmarks(
            libraryItemId: book.id,
            localBookmarks: local,
            storageBookId: book.stableId,
            mediaType: .audiobook,
            backend: backend
        )
        bookmarkService.replaceBookmarks(bookId: book.stableId, bookmarks: merged)
    }

    private func syncBookOrbitBookmarks(book: Book) async {
        guard book.source == .bookOrbit,
            let provider = providerConnections.provider(for: book.providerId) as? BookOrbitProvider
        else { return }
        _ = await BookOrbitReaderArtifactSync.shared.sync(book: book, provider: provider)
    }

    // MARK: - Sleep timer fire state

    // tvOS clears stale sleep-timer markers without presenting the iOS rewind prompt.
    private func clearStaleSleepTimerFireState(for book: Book) {
        guard let state = PlayerStateStore.shared.loadSleepTimer(),
            let firedDate = state.timerFiredDate,
            state.timerFiredPosition != nil,
            let firedBookId = state.timerFiredBookId,
            firedBookId == book.id
        else { return }

        guard Date().timeIntervalSince(firedDate) >= 600 else { return }

        var cleared = state
        cleared.timerFiredDate = nil
        cleared.timerFiredPosition = nil
        cleared.timerFiredBookId = nil
        cleared.timerStartedDate = nil
        PlayerStateStore.shared.saveSleepTimer(cleared)
    }

    func prewarmRestoredBook(_ book: Book, resumeAt: TimeInterval?) {
        prewarmTask?.cancel()
        prewarmTask = Task { [weak self] in
            await self?.prepareRestoredBookForPlayback(book, resumeAt: resumeAt)
        }
    }

    private func prepareRestoredBookForPlayback(_ book: Book, resumeAt: TimeInterval?) async {
        let prewarmToken = activePlayToken
        guard controller.snapshot.currentBook == nil,
            !controller.snapshot.isLoaded,
            !controller.snapshot.isPlaying
        else { return }

        if book.source == .storyteller {
            AppLogger.player.debug(
                "Skipping restored prewarm for Storyteller session bookDiagnosticID=\(diagnosticBookID(book))"
            )
            return
        }

        await chapterService.loadChapters(for: book)

        do {
            try Task.checkCancellation()
            guard let streamURL = try await streamResolver.streamURL(for: book) else { return }
            try Task.checkCancellation()
            guard activePlayToken == prewarmToken else { return }

            loader.load(url: streamURL, book: book, startingAt: 0)

            if streamURL.isFileURL {
                try await Task.sleep(nanoseconds: 500_000_000)

                if let playerError = controller.snapshot.errorDescription {
                    AppLogger.player.error("Local prewarm failed: \(playerError). Trying remote stream...")
                    LocalStorageManager.shared.markNeedsReVerification(bookId: book.id)
                    if let remoteURL = try await streamResolver.remoteStreamURL(for: book) {
                        try Task.checkCancellation()
                        guard activePlayToken == prewarmToken else { return }
                        loader.load(url: remoteURL, book: book, startingAt: 0)
                    }
                }
            }

            guard activePlayToken == prewarmToken else { return }

            if let resumeAt {
                controller.seek(to: resumeAt)
            }

            controller.setPlaybackRate(LibraryDisplayPreferencesStore.shared.loadPreferences().playbackSpeed)
            loader.setupNowPlaying(book: book)
            loader.updateNowPlayingInfo()

            AppLogger.player.debug("Prewarmed restored bookDiagnosticID=\(diagnosticBookID(book))")
        } catch is CancellationError {
            return
        } catch {
            if Self.isProviderUnavailableError(error) {
                AppLogger.player.debug(
                    "Skipping prewarm for bookDiagnosticID=\(diagnosticBookID(book)); provider not configured: \(error.localizedDescription)"
                )
            } else {
                AppLogger.player.error("Failed to prewarm restored book: \(error)")
            }
        }
    }

    private static func isProviderUnavailableError(_ error: Error) -> Bool {
        let msg = error.localizedDescription
        return msg.contains("provider not available") || msg.contains("not available")
    }

    // MARK: - Chapter enrichment

    private func enrichChaptersIfNeeded(for book: Book, streamURL: URL) async {
        let hasChapters = !chapterService.chapters.isEmpty
        let hasDownloadedAudio = !(LocalStorageManager.shared.localAudiobookFilesIfExists(for: book) ?? []).isEmpty
        let shouldRefreshDownloadedGrimmory = book.source == .booklore && hasDownloadedAudio
        guard !hasChapters || shouldRefreshDownloadedGrimmory else { return }

        switch book.source {
        case .audiobookshelf:
            if let session = sessionService.lastSession {
                let resolved = absChapters(from: session)
                if !resolved.isEmpty {
                    applyResolvedChapters(resolved, for: book, source: "ABS session")
                    return
                }
            }

            let enrichedBook = await refreshedAudiobookshelfBookForChapterExtraction(book) ?? book
            if let detailChapters = enrichedBook.chapters, !detailChapters.isEmpty {
                applyResolvedChapters(detailChapters, for: book, source: "ABS item detail")
                return
            }

            await loadAudiobookshelfChaptersFromFileOrStream(for: enrichedBook, streamURL: streamURL)

        case .storyteller:
            if let provider = providerConnections.provider(for: book.providerId) as? StorytellerProvider {
                if let manifestChapters = try? await provider.fetchManifestChapters(for: book), !manifestChapters.isEmpty {
                    AppLogger.player.debug(
                        "Applying \(manifestChapters.count) Storyteller manifest chapters for bookDiagnosticID=\(diagnosticBookID(book))"
                    )
                    chapterService.applyChapters(manifestChapters, for: book)
                    return
                }

                if let session = try? await provider.startPlaybackSession(for: book) {
                    if !session.chapters.isEmpty {
                        AppLogger.player.debug(
                            "Applying \(session.chapters.count) Storyteller session chapters for bookDiagnosticID=\(diagnosticBookID(book))"
                        )
                        chapterService.applyChapters(session.chapters, for: book)
                        return
                    }

                    if session.audioTracks.count > 1 {
                        let synthesized = trackBasedChapters(from: session.audioTracks, idPrefix: "storyteller_track")
                        AppLogger.player.debug(
                            "Synthesized \(synthesized.count) Storyteller track chapters for bookDiagnosticID=\(diagnosticBookID(book))"
                        )
                        chapterService.applyChapters(synthesized, for: book)
                        return
                    }

                    if let trackURL = session.audioTracks.first.flatMap({ URL(string: $0.contentUrl) }) {
                        await extractChaptersFromAsset(url: trackURL, book: book)
                        return
                    }
                }
                await extractChaptersFromAsset(url: streamURL, headers: provider.getStreamingHeaders(), book: book)
            } else {
                await extractChaptersFromAsset(url: streamURL, book: book)
            }

        case .booklore:
            if let provider = providerConnections.provider(for: book.providerId) as? BookloreProvider,
                let session = try? await provider.startPlaybackSession(for: book)
            {
                let headers = provider.getStreamingHeaders()

                let bookDuration = book.duration ?? session.audioTracks.reduce(0) { $0 + $1.duration }
                let sessionChaptersAdequate = session.chapters.count > 1 || (session.chapters.count == 1 && bookDuration <= 1800)

                if !session.chapters.isEmpty && sessionChaptersAdequate {
                    AppLogger.player.debug(
                        "Applying \(session.chapters.count) chapters from Grimmory session for bookDiagnosticID=\(diagnosticBookID(book))"
                    )
                    chapterService.applyChapters(session.chapters, for: book)
                } else if session.audioTracks.count == 1,
                    let trackURL = session.audioTracks.first.flatMap({ URL(string: $0.contentUrl) })
                {
                    AppLogger.player.debug(
                        "Extracting embedded chapters from Grimmory track for bookDiagnosticID=\(diagnosticBookID(book))"
                    )
                    await extractChaptersFromAsset(url: trackURL, headers: provider.getStreamingHeaders(), book: book)
                } else if session.audioTracks.count > 1 {
                    let synthesized = trackBasedChapters(from: session.audioTracks, idPrefix: "grimmory_track")
                    AppLogger.player.debug(
                        "Synthesized \(synthesized.count) track-based chapters for bookDiagnosticID=\(diagnosticBookID(book))"
                    )
                    chapterService.applyChapters(synthesized, for: book)
                }

                if session.audioTracks.count > 1 {
                    var offset: TimeInterval = 0
                    let tracks: [AudioTrack] = session.audioTracks.map { info in
                        let resolvedOffset = info.startOffset > 0 ? info.startOffset : offset
                        let track = AudioTrack(
                            index: info.index,
                            title: info.title,
                            contentUrl: info.contentUrl,
                            duration: info.duration,
                            startOffset: resolvedOffset,
                            headers: headers
                        )
                        offset = resolvedOffset + info.duration
                        return track
                    }
                    resolvedGrimmoryTracks = tracks
                    AppLogger.player.debug(
                        "Resolved \(tracks.count) Grimmory streaming tracks for bookDiagnosticID=\(diagnosticBookID(book))"
                    )
                }
            } else {
                await extractChaptersFromAsset(url: streamURL, book: book)
            }

        case .plex, .jellyfin, .emby, .local, .webdav, .torbox, .realdebrid, .bookOrbit, .silo:
            await extractChaptersFromAsset(url: streamURL, book: book)

        case .smb:
            await loadSMBChapters(for: book)

        case .komga, .kavita, .opds:
            break
        }
    }

    private func applyResolvedChapters(_ resolved: [Chapter], for book: Book, source: String) {
        guard !resolved.isEmpty else { return }
        AppLogger.player.debug(
            "Applying \(resolved.count) chapters from \(source) for bookDiagnosticID=\(diagnosticBookID(book))"
        )
        chapterService.applyChapters(resolved, for: book)
        _ = libraryCache.mutateBook(uniqueId: book.uniqueId) { $0.chapters = resolved }
        chapterService.updateCurrentChapter(at: controller.snapshot.position)
    }

    private func refreshedAudiobookshelfBookForChapterExtraction(_ book: Book) async -> Book? {
        guard NetworkPolicyService.shared.isConnected,
            let provider = providerConnections.provider(for: book.providerId)
        else {
            return nil
        }

        do {
            let refreshed = try await provider.fetchFullBookDetails(bookId: book.id, libraryId: book.libraryId)
            let chapterCount = refreshed.chapters?.count ?? 0
            AppLogger.player.info(
                "Fetched ABS item detail for chapter enrichment bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) chapters=\(chapterCount) hasInode=\(refreshed.audioFileIno != nil)"
            )
            return refreshed
        } catch {
            AppLogger.player.warning("Failed to fetch ABS item detail for chapter enrichment: \(error.localizedDescription)")
            return nil
        }
    }

    private func absChapters(from session: ABSPlaySession) -> [Chapter] {
        if let chapters = session.chapters, !chapters.isEmpty {
            return chapters.enumerated().map { index, chapter in
                Chapter(id: "abs_ch_\(chapter.id)", start: chapter.start, end: chapter.end, title: chapter.title, index: index)
            }
        }

        if let audioFiles = session.libraryItem?.media?.audioFiles {
            let nested = nestedABSAudioFileChapters(from: audioFiles)
            if !nested.isEmpty { return nested }
        }

        if let tracks = session.audioTracks, tracks.count > 1 {
            var offset: TimeInterval = 0
            return tracks.enumerated().compactMap { index, track in
                let start = track.startOffset ?? offset
                let end = start + max(track.duration ?? 0, 0)
                offset = end
                guard end > start else { return nil }
                return Chapter(
                    id: "abs_track_\(track.index ?? index)",
                    start: start,
                    end: end,
                    title: track.title ?? track.metadata?.filename ?? "Track \(index + 1)",
                    index: index
                )
            }
        }

        return []
    }

    private func nestedABSAudioFileChapters(from audioFiles: [ABSAudioFile]) -> [Chapter] {
        var chapters: [Chapter] = []
        var fileOffset: TimeInterval = 0

        for (fileIndex, file) in audioFiles.enumerated() {
            for chapter in file.chapters ?? [] {
                let start = fileOffset + chapter.start
                let end = fileOffset + chapter.end
                guard end > start else { continue }
                chapters.append(
                    Chapter(
                        id: "abs_file_\(fileIndex)_\(chapter.id)",
                        start: start,
                        end: end,
                        title: chapter.title,
                        index: chapters.count
                    )
                )
            }
            fileOffset += file.duration ?? 0
        }

        return chapters
    }

    private func trackBasedChapters(from tracks: [AudioTrackInfo], idPrefix: String) -> [Chapter] {
        var offset: TimeInterval = 0
        return tracks.enumerated().compactMap { index, track in
            let start = track.startOffset > 0 ? track.startOffset : offset
            let end = start + max(track.duration, 0)
            offset = end
            guard end > start else { return nil }
            return Chapter(
                id: "\(idPrefix)_\(track.index)",
                start: start,
                end: end,
                title: track.title ?? "Track \(index + 1)",
                index: index
            )
        }
    }

    private func loadSMBChapters(for book: Book) async {
        AppLogger.player.debug("SMB: Loading chapters for bookDiagnosticID=\(diagnosticBookID(book))")

        if let localURL = LocalStorageManager.shared.localAudiobookFileURLIfExists(bookId: book.downloadKey) {
            AppLogger.player.debug(
                "SMB: Using local download for chapter extraction: \(DiagnosticLogSanitizer.fileDescriptor(for: localURL))"
            )
            await extractChaptersFromAsset(url: localURL, book: book)
            return
        }

        guard let sourceId = book.backendId else {
            AppLogger.player.info("SMB: No sourceId for chapter extraction")
            return
        }

        let smbBooks = await SMBLibraryService.shared.getBooks(for: sourceId)
        guard let smbBook = smbBooks.first(where: { $0.id == book.id }),
            !smbBook.audioFiles.isEmpty
        else {
            AppLogger.player.warning("SMB: Book not found for chapter extraction")
            return
        }

        AppLogger.player.debug("SMB: extracting chapters via streaming")

        do {
            guard let streamURL = try await SMBStreamingServer.shared.startStreaming(book: book) else {
                AppLogger.player.error("SMB: Failed to get stream URL")
                return
            }

            await extractChaptersFromAsset(url: streamURL, book: book)

        } catch {
            AppLogger.player.error("SMB: Failed to start stream for chapters: \(error.localizedDescription)")
        }
    }

    private func loadAudiobookshelfChaptersFromFileOrStream(for book: Book, streamURL: URL) async {
        if let localFiles = LocalStorageManager.shared.localAudiobookFilesIfExists(for: book) {
            for localURL in localFiles {
                if await extractChaptersFromAsset(url: localURL, book: book) {
                    AppLogger.player.debug(
                        "Loaded ABS chapters from downloaded file: \(DiagnosticLogSanitizer.fileDescriptor(for: localURL))"
                    )
                    return
                }
            }
        }

        let provider = providerConnections.capability(PlaybackSessionProvider.self, for: book)
        let headers = provider?.getStreamingHeaders()
        if let fileURL = provider?.chapterExtractionURL(for: book), fileURL != streamURL {
            if await extractChaptersFromAsset(url: fileURL, headers: fileURL.isFileURL ? nil : headers, book: book) {
                AppLogger.player.debug(
                    "Loaded ABS chapters from direct file URL for bookDiagnosticID=\(diagnosticBookID(book))"
                )
                return
            }
        }

        _ = await extractChaptersFromAsset(url: streamURL, headers: headers, book: book)
    }

    @discardableResult
    private func extractChaptersFromAsset(url: URL, headers: [String: String]? = nil, book: Book) async -> Bool {
        let options = (headers?.isEmpty == false) ? ["AVURLAssetHTTPHeaderFieldsKey": headers!] : [:]
        let asset = AVURLAsset(url: url, options: options)

        do {
            if !url.isFileURL,
                let ranged = await RemoteMP4ChapterExtractor.extractChapters(
                    from: url,
                    headers: headers ?? [:],
                    durationHint: book.duration
                ),
                !ranged.isEmpty
            {
                applyExtractedChapters(ranged, book: book)
                return true
            }

            let chapterLocales = try await asset.load(.availableChapterLocales)
            AppLogger.player.info("Found \(chapterLocales.count) chapter locales")

            var extractedChapters: [Chapter] = []

            for locale in chapterLocales {
                let chapterGroups = try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [])

                for (index, group) in chapterGroups.enumerated() {
                    let timeRange = group.timeRange
                    let startTime = CMTimeGetSeconds(timeRange.start)
                    let duration = CMTimeGetSeconds(timeRange.duration)
                    let endTime = startTime + duration

                    var title = "Chapter \(index + 1)"
                    for item in group.items {
                        if let titleValue = try? await item.load(.stringValue), !titleValue.isEmpty {
                            title = titleValue
                            break
                        }
                    }

                    let chapter = Chapter(
                        id: "chapter_\(index)",
                        title: title,
                        startTime: startTime,
                        endTime: endTime,
                        duration: duration,
                        index: index + 1
                    )
                    extractedChapters.append(chapter)
                }

                if !extractedChapters.isEmpty {
                    break
                }
            }

            if extractedChapters.isEmpty,
                let fallbackGroups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
            {
                for (index, group) in fallbackGroups.enumerated() {
                    let timeRange = group.timeRange
                    let startTime = CMTimeGetSeconds(timeRange.start)
                    let duration = CMTimeGetSeconds(timeRange.duration)
                    let endTime = startTime + duration

                    var title = "Chapter \(index + 1)"
                    for item in group.items {
                        if let titleValue = try? await item.load(.stringValue), !titleValue.isEmpty {
                            title = titleValue
                            break
                        }
                    }

                    let chapter = Chapter(
                        id: "chapter_\(index)",
                        title: title,
                        startTime: startTime,
                        endTime: endTime,
                        duration: duration,
                        index: index + 1
                    )
                    extractedChapters.append(chapter)
                }
            }

            if extractedChapters.isEmpty {
                let assetDuration = (try? await asset.load(.duration)).map(CMTimeGetSeconds)
                extractedChapters = await extractID3Chapters(from: url, headers: headers, totalDuration: assetDuration)
            }

            extractedChapters.sort { $0.start < $1.start }

            if extractedChapters.isEmpty {
                AppLogger.player.info("No chapters found in audio file")
                return false
            }

            applyExtractedChapters(extractedChapters, book: book)
            return true

        } catch {
            AppLogger.player.error("Failed to extract chapters: \(error.localizedDescription)")
            return false
        }
    }

    private func applyExtractedChapters(_ extractedChapters: [Chapter], book: Book) {
        chapterService.applyChapters(extractedChapters, for: book)
        AppLogger.player.info("Loaded \(extractedChapters.count) chapters from audio file")
        chapterService.updateCurrentChapter(at: controller.snapshot.position)

        ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.stableId, chapters: extractedChapters)
        if book.id != book.stableId {
            ReaderArtifactsStore.shared.saveCachedChapters(bookId: book.id, chapters: extractedChapters)
        }
        _ = libraryCache.mutateBook(uniqueId: book.uniqueId) { $0.chapters = extractedChapters }
    }

    // MARK: - ID3 chapter parsing

    private func extractID3Chapters(from url: URL, headers: [String: String]?, totalDuration: TimeInterval?) async -> [Chapter] {
        guard let tagData = await loadID3TagData(from: url, headers: headers) else { return [] }
        return parseID3Chapters(from: tagData, totalDuration: totalDuration)
    }

    private func loadID3TagData(from url: URL, headers: [String: String]?) async -> Data? {
        let maxTagBytes = 8 * 1024 * 1024

        if url.isFileURL {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let header = try? handle.read(upToCount: 10),
                let totalSize = id3TotalSize(from: header),
                totalSize <= maxTagBytes
            else {
                return nil
            }
            try? handle.seek(toOffset: 0)
            return try? handle.read(upToCount: totalSize)
        }

        func rangedRequest(_ range: String) -> URLRequest {
            var request = URLRequest(url: url)
            request.setValue(range, forHTTPHeaderField: "Range")
            headers?.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            return request
        }

        do {
            let (headerData, _) = try await URLSession.shared.data(for: rangedRequest("bytes=0-9"))
            guard let totalSize = id3TotalSize(from: headerData),
                totalSize <= maxTagBytes
            else {
                return nil
            }
            if headerData.count >= totalSize {
                return headerData.prefix(totalSize)
            }
            let (tagData, _) = try await URLSession.shared.data(for: rangedRequest("bytes=0-\(totalSize - 1)"))
            guard tagData.count >= totalSize else { return nil }
            return tagData.prefix(totalSize)
        } catch {
            AppLogger.player.warning("Failed to load ID3 tag for chapter extraction: \(error.localizedDescription)")
            return nil
        }
    }

    private func id3TotalSize(from data: Data) -> Int? {
        let bytes = Array(data.prefix(10))
        guard bytes.count >= 10,
            bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33
        else {
            return nil
        }
        return 10 + Int(id3SyncSafe(bytes[6], bytes[7], bytes[8], bytes[9]))
    }

    private func parseID3Chapters(from data: Data, totalDuration: TimeInterval?) -> [Chapter] {
        let bytes = Array(data)
        guard bytes.count >= 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return [] }

        let majorVersion = bytes[3]
        guard majorVersion == 3 || majorVersion == 4 else { return [] }

        let tagSize = Int(id3SyncSafe(bytes[6], bytes[7], bytes[8], bytes[9]))
        let tagEnd = min(bytes.count, 10 + tagSize)
        var offset = 10

        if bytes[5] & 0x40 != 0, offset + 4 <= tagEnd {
            let extendedSize =
                majorVersion == 4
                ? Int(id3SyncSafe(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]))
                : Int(id3UInt32(bytes, offset))
            offset += max(extendedSize, 4)
        }

        struct ParsedChapter {
            let title: String
            let start: TimeInterval
            let end: TimeInterval
        }

        var parsed: [ParsedChapter] = []

        while offset + 10 <= tagEnd {
            let frameIDBytes = Array(bytes[offset..<offset + 4])
            if frameIDBytes.allSatisfy({ $0 == 0 }) { break }
            guard let frameID = String(bytes: frameIDBytes, encoding: .ascii),
                frameID.allSatisfy({ $0.isLetter || $0.isNumber })
            else {
                break
            }

            let frameSize =
                majorVersion == 4
                ? Int(id3SyncSafe(bytes[offset + 4], bytes[offset + 5], bytes[offset + 6], bytes[offset + 7]))
                : Int(id3UInt32(bytes, offset + 4))
            guard frameSize > 0 else { break }

            let payloadStart = offset + 10
            let payloadEnd = payloadStart + frameSize
            guard payloadEnd <= tagEnd else { break }

            if frameID == "CHAP",
                let chapter = parseID3ChapterFrame(Array(bytes[payloadStart..<payloadEnd]), majorVersion: majorVersion)
            {
                parsed.append(ParsedChapter(title: chapter.title, start: chapter.start, end: chapter.end))
            }

            offset = payloadEnd
        }

        let sorted = parsed.sorted { $0.start < $1.start }
        let chapters = sorted.enumerated().compactMap { index, chapter -> Chapter? in
            let fallbackEnd = sorted.indices.contains(index + 1) ? sorted[index + 1].start : totalDuration
            let end = chapter.end > chapter.start ? chapter.end : (fallbackEnd ?? chapter.start)
            guard end > chapter.start else { return nil }
            return Chapter(
                id: "id3_chapter_\(index)",
                start: chapter.start,
                end: end,
                title: chapter.title,
                index: index
            )
        }

        if !chapters.isEmpty {
            AppLogger.player.info("Loaded \(chapters.count) chapters from ID3 chapter frames")
        }
        return chapters
    }

    private func parseID3ChapterFrame(_ payload: [UInt8], majorVersion: UInt8) -> (title: String, start: TimeInterval, end: TimeInterval)? {
        guard let idTerminator = payload.firstIndex(of: 0x00),
            idTerminator + 17 <= payload.count
        else {
            return nil
        }

        var offset = idTerminator + 1
        let startMS = id3UInt32(payload, offset)
        offset += 4
        let endMS = id3UInt32(payload, offset)
        offset += 12

        var title: String?
        while offset + 10 <= payload.count {
            let frameIDBytes = Array(payload[offset..<offset + 4])
            if frameIDBytes.allSatisfy({ $0 == 0 }) { break }
            guard let frameID = String(bytes: frameIDBytes, encoding: .ascii) else { break }
            let frameSize =
                majorVersion == 4
                ? Int(id3SyncSafe(payload[offset + 4], payload[offset + 5], payload[offset + 6], payload[offset + 7]))
                : Int(id3UInt32(payload, offset + 4))
            guard frameSize > 0 else { break }

            let payloadStart = offset + 10
            let payloadEnd = payloadStart + frameSize
            guard payloadEnd <= payload.count else { break }

            if frameID == "TIT2" {
                title = decodeID3TextFrame(Array(payload[payloadStart..<payloadEnd]))
                break
            }

            offset = payloadEnd
        }

        let start = TimeInterval(startMS) / 1000.0
        let end = endMS == UInt32.max ? start : TimeInterval(endMS) / 1000.0
        return (blankToNil(title) ?? "Chapter", start, end)
    }

    private func decodeID3TextFrame(_ payload: [UInt8]) -> String? {
        guard let encoding = payload.first else { return nil }
        let content = trimmingTrailingNulls(Array(payload.dropFirst()))
        let stringEncoding: String.Encoding =
            switch encoding {
            case 0x00: .isoLatin1
            case 0x01: .utf16
            case 0x02: .utf16BigEndian
            case 0x03: .utf8
            default: .utf8
            }
        return blankToNil(String(bytes: content, encoding: stringEncoding))
    }

    private func blankToNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func trimmingTrailingNulls(_ bytes: [UInt8]) -> [UInt8] {
        var trimmed = bytes
        while trimmed.last == 0x00 {
            trimmed.removeLast()
        }
        return trimmed
    }

    private func id3SyncSafe(_ b0: UInt8, _ b1: UInt8, _ b2: UInt8, _ b3: UInt8) -> UInt32 {
        (UInt32(b0 & 0x7F) << 21)
            | (UInt32(b1 & 0x7F) << 14)
            | (UInt32(b2 & 0x7F) << 7)
            | UInt32(b3 & 0x7F)
    }

    private func id3UInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 3 < bytes.count else { return 0 }
        return (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }
}
#endif
