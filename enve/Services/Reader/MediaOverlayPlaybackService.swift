import AVFoundation
import Foundation
import Logging
@preconcurrency import ReadiumShared
@preconcurrency import ReadiumStreamer
import UIKit

@MainActor
final class MediaOverlayPlaybackService {
    static let shared = MediaOverlayPlaybackService()
    private let playback: any PlaybackControlling
    private let overlayController: (any PlaybackOverlayControlling)?
    private let bookSession: any CurrentBookSession
    private let libraryCache: LibraryBookCache
    private let presentation: AppPresentationState
    private let providerResolver: any LibraryProviderResolving
    private let bookRepository: BookStoreRepository

    private init(
        playbackComposition: PlaybackComposition = ActivePlayback.composition,
        bookSession: any CurrentBookSession = AppState.shared,
        libraryCache: LibraryBookCache = AppState.shared.libraryCache,
        presentation: AppPresentationState = AppState.shared.presentation,
        providerResolver: any LibraryProviderResolving = AppState.shared.providerConnections,
        bookRepository: BookStoreRepository = AppState.shared.bookStore
    ) {
        self.playback = playbackComposition.controller
        self.overlayController = playbackComposition.overlayController
        self.bookSession = bookSession
        self.libraryCache = libraryCache
        self.presentation = presentation
        self.providerResolver = providerResolver
        self.bookRepository = bookRepository
    }

    private(set) var activeResult: OverlayAudioResult?
    private(set) var activeBookId: String?
    private(set) var activeBookStableId: String?
    private(set) var activeBookUniqueId: String?
    private(set) var activeReadAloudSourceStableId: String?
    private var activeProviderId: UUID?
    private var positionSyncTask: Task<Void, Never>?
    private var positionSyncGeneration = 0
    private var playGeneration = 0

    struct OverlayAudioResult {
        let tracks: [AudioTrackInfo]
        let totalDuration: TimeInterval
        let chapters: [Chapter]
        let timeline: MediaOverlayTimeline
        let audioDirectory: URL
    }

    private struct ReadAloudIndex: Codable {
        let schemaVersion: Int
        let fileSignature: String
        let clips: [AudioOverlayClip]
        let audioDurationsBySource: [String: TimeInterval]
        let chapters: [Chapter]
    }

    func prepareAudioTracks(for book: Book) async throws -> OverlayAudioResult {
        guard let fileURL = resolveEbookFile(for: book) else {
            throw OverlayPlaybackError.noEbookFile
        }
        return try await prepareAudioTracks(for: book, fileURL: fileURL)
    }

    private func prepareAudioTracks(for book: Book, fileURL: URL) async throws -> OverlayAudioResult {
        if let cached = loadIndexedAudioTracks(for: book, epubFileURL: fileURL) {
            return cached
        }

        guard let readiumURL = FileURL(url: fileURL) else {
            throw OverlayPlaybackError.invalidURL(fileURL.path)
        }

        let httpClient = DefaultHTTPClient()
        let assetRetriever = AssetRetriever(httpClient: httpClient)
        let publicationOpener = PublicationOpener(
            parser: DefaultPublicationParser(
                httpClient: httpClient,
                assetRetriever: assetRetriever,
                pdfFactory: DefaultPDFDocumentFactory()
            )
        )

        let asset = try await assetRetriever.retrieve(url: readiumURL).get()
        let publication = try await publicationOpener.open(asset: asset, allowUserInteraction: false).get()

        let clips = try await EPUB3SMILParser.parse(publication: publication, epubFileURL: fileURL)
        guard !clips.isEmpty else {
            throw OverlayPlaybackError.noOverlayClips
        }

        var seenSrcs = [String]()
        var srcSpans = [String: (begin: TimeInterval, end: TimeInterval)]()

        for clip in clips {
            let src = clip.audioSrc
            if srcSpans[src] == nil {
                seenSrcs.append(src)
                srcSpans[src] = (begin: clip.clipBegin, end: clip.clipEnd)
            }
            if let span = srcSpans[src] {
                srcSpans[src] = (
                    begin: min(span.begin, clip.clipBegin),
                    end: max(span.end, clip.clipEnd)
                )
            }
        }

        let cachedAudio = cachedReadAloudAudioFiles(for: book, sources: seenSrcs)
        let audioDir: URL
        let srcFileURLs: [String: URL]
        if let cachedAudio {
            audioDir = cachedAudio.directory
            srcFileURLs = cachedAudio.filesBySource
        } else {
            audioDir = try await EPUB3SMILParser.extractAudio(
                clips: clips,
                publication: publication,
                bookId: book.stableId,
                epubFileURL: fileURL
            )
            srcFileURLs = Dictionary(
                uniqueKeysWithValues: seenSrcs.map {
                    ($0, EPUB3SMILParser.localAudioURL(for: $0, in: audioDir))
                }
            )
        }

        var srcDurations = [String: TimeInterval]()
        for src in seenSrcs {
            guard let url = srcFileURLs[src] else { continue }
            let realDuration = await probeAudioDuration(url: url)
            if let span = srcSpans[src] {
                srcDurations[src] = max(realDuration ?? span.end, span.end)
            } else {
                srcDurations[src] = realDuration ?? 0
            }
        }

        let timeline = MediaOverlayTimeline(
            clips: clips,
            audioDurationsBySource: srcDurations
        )

        var tracks = [AudioTrackInfo]()
        for (index, src) in seenSrcs.enumerated() {
            guard let url = srcFileURLs[src],
                let duration = timeline.duration(forAudioSource: src),
                let startOffset = timeline.audioStart(forAudioSource: src)
            else { continue }
            let track = AudioTrackInfo(
                index: index,
                startOffset: startOffset,
                duration: duration,
                contentUrl: url.absoluteString,
                mimeType: guessMimeType(for: url)
            )
            tracks.append(track)
        }

        let totalDuration = timeline.totalAudioDuration
        let clipGlobalTimes = timeline.clipTimings.map { (start: $0.audioStart, end: $0.audioEnd) }

        let chapters = await buildOverlayChapters(
            publication: publication,
            clips: clips,
            clipGlobalTimes: clipGlobalTimes
        )

        AppLogger.library.info(
            "MediaOverlayPlayback: \(tracks.count) tracks, \(clips.count) clips, total \(String(format: "%.1f", totalDuration))s for \(book.title)"
        )

        let result = OverlayAudioResult(
            tracks: tracks,
            totalDuration: totalDuration,
            chapters: chapters,
            timeline: timeline,
            audioDirectory: audioDir
        )

        saveReadAloudIndexIfPersistent(
            for: book,
            epubFileURL: fileURL,
            clips: clips,
            audioDurationsBySource: srcDurations,
            chapters: chapters,
            audioDirectory: audioDir
        )

        return result
    }

    @discardableResult
    func buildPersistentIndex(for book: Book, epubURL: URL) async -> Bool {
        do {
            _ = try await prepareAudioTracks(for: book, fileURL: epubURL)
            return true
        } catch {
            AppLogger.library.warning(
                "MediaOverlayPlayback: failed to build read-aloud index for \(book.title): \(error.localizedDescription)"
            )
            return false
        }
    }

    func play(_ book: Book, presentPlayer: Bool = true) async throws {
        guard let overlayController else { throw OverlayPlaybackError.unsupportedPlatform }
        playGeneration += 1
        let generation = playGeneration
        var playbackBook = await refreshedBookForPlayback(book)
        try validatePlayRequest(generation)

        if activeResult != nil,
            activeBookUniqueId == playbackBook.uniqueId,
            playback.snapshot.isOverlayPlaybackActive
        {
            let managerBook = playback.snapshot.currentBook
            let readingPositionIsNewer =
                managerBook.map {
                    playbackBook.lastUpdate > $0.lastUpdate
                } ?? false
            let liveTime: TimeInterval
            if readingPositionIsNewer, let activeResult {
                liveTime = resumeTime(for: playbackBook, result: activeResult)
                playback.seek(to: liveTime)
            } else {
                liveTime = playback.snapshot.position
            }
            if !playback.snapshot.isPlaying {
                playback.play()
            }
            try validatePlayRequest(generation)
            playbackBook.currentTime = liveTime
            bookSession.currentBook = playbackBook
            presentation.isPlayerPresented = presentPlayer
            return
        }

        var installedSessionId: String?
        do {
            let result = try await prepareAudioTracks(for: playbackBook)
            try validatePlayRequest(generation)

            playbackBook.duration = result.totalDuration
            if !result.chapters.isEmpty {
                playbackBook.chapters = result.chapters
                ReaderArtifactsStore.shared.saveCachedChapters(bookId: playbackBook.stableId, chapters: result.chapters)
                if playbackBook.id != playbackBook.stableId {
                    ReaderArtifactsStore.shared.saveCachedChapters(bookId: playbackBook.id, chapters: result.chapters)
                }
            }

            let updatedBook = libraryCache.mutateBook(uniqueId: playbackBook.uniqueId) { book in
                book.duration = result.totalDuration
                if !result.chapters.isEmpty {
                    book.chapters = result.chapters
                }
            }
            if let updated = updatedBook {
                playbackBook = updated
            }
            await bookRepository.upsertBooks([playbackBook])
            try validatePlayRequest(generation)

            let resumeTime = resumeTime(for: playbackBook, result: result)
            installedSessionId = try await overlayController.playOverlayTracks(
                result.tracks,
                book: playbackBook,
                totalDuration: result.totalDuration,
                resumeTime: resumeTime
            )
            try validatePlayRequest(generation)

            activeResult = result
            activeBookId = playbackBook.id
            activeBookStableId = playbackBook.stableId
            activeBookUniqueId = playbackBook.uniqueId
            activeReadAloudSourceStableId = playbackBook.readAloudSourceStableId
            activeProviderId = playbackBook.providerId

            playbackBook.currentTime = resumeTime
            bookSession.currentBook = playbackBook
            presentation.isPlayerPresented = presentPlayer
            playback.play()
        } catch {
            if let installedSessionId {
                overlayController.stopOverlaySession(ifMatching: installedSessionId)
            }
            throw error
        }
    }

    func clearActiveResult() {
        activeResult = nil
        activeBookId = nil
        activeBookStableId = nil
        activeBookUniqueId = nil
        activeReadAloudSourceStableId = nil
        activeProviderId = nil
    }

    func cancelPendingPlay() {
        playGeneration += 1
    }

    private func validatePlayRequest(_ generation: Int) throws {
        guard generation == playGeneration else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func refreshedBookForPlayback(_ book: Book) async -> Book {
        var current = libraryCache.bookInMemory(uniqueId: book.uniqueId) ?? book
        if current.isStorytellerReadAloud {
            guard let provider = providerResolver.provider(for: current.providerId) as? StorytellerProvider,
                let authoritative = await StorytellerPositionSyncService.shared.authoritativePosition(
                    for: current,
                    through: provider
                )
            else { return current }
            let position = authoritative.position
            if let updated = libraryCache.mutateBook(
                uniqueId: current.uniqueId,
                { updated in
                    updated.ebookProgress = position.progression
                    updated.epubLocator = position.locatorJSON
                    updated.lastUpdate = position.observedAt
                }
            ) {
                current = updated
            }
            await bookRepository.updateEbookProgress(
                uniqueId: current.uniqueId,
                ebookProgress: position.progression,
                epubLocator: position.locatorJSON,
                isFinished: position.progression >= 0.99,
                lastUpdate: position.observedAt
            )
            return current
        }
        guard current.source == .storyteller,
            let provider = providerResolver.provider(for: current.providerId) as? StorytellerProvider,
            let server = try? await provider.fetchEbookProgress(for: current),
            let serverDate = server.updatedAt
        else { return current }
        current = libraryCache.bookInMemory(uniqueId: book.uniqueId) ?? current
        guard serverDate > current.lastUpdate else { return current }

        if let updated = libraryCache.mutateBook(
            uniqueId: current.uniqueId,
            { updated in
                updated.ebookProgress = server.progress
                if let locator = server.locator, !locator.isEmpty {
                    updated.epubLocator = locator
                }
                updated.lastUpdate = serverDate
            }
        ) {
            current = updated
        }
        await bookRepository.updateEbookProgress(
            uniqueId: current.uniqueId,
            ebookProgress: server.progress,
            epubLocator: server.locator,
            isFinished: current.isFinished,
            lastUpdate: serverDate
        )
        return current
    }

    private func resumeTime(for book: Book, result: OverlayAudioResult) -> TimeInterval {
        if let locator = book.epubLocator,
            let resolved = result.timeline.resolveEPUB3Locator(locatorJSON: locator)
        {
            return resolved.audioTime
        }
        return 0
    }

    func syncCurrentPlaybackPositionIfActive(for book: Book) {
        let snapshot = playback.snapshot
        guard snapshot.isOverlayPlaybackActive,
            let playbackBook = snapshot.currentBook,
            activeBookMatches(playbackBook),
            activeBookMatches(book)
        else { return }
        syncEbookPositionFromAudio(audioTime: snapshot.position, book: playbackBook)
    }

    func syncEbookPositionFromAudio(
        audioTime: TimeInterval,
        book: Book,
        authoritative: Bool = false
    ) {
        guard let result = activeResult, activeBookMatches(book) else { return }
        guard let idx = result.timeline.clipIndex(atAudioTime: audioTime) else { return }

        let clampedAudioTime = min(max(audioTime, 0), result.totalDuration)
        let ebookProgress = result.timeline.spokenProgression(
            atAudioTime: clampedAudioTime,
            clipIndex: idx
        )

        guard
            let jsonString = result.timeline.textLocatorJSONString(
                clipIndex: idx,
                audioTime: clampedAudioTime,
                totalProgression: ebookProgress
            )
        else {
            return
        }

        let now = Date()
        let current = libraryCache.bookInMemory(uniqueId: book.uniqueId) ?? book
        var syncBook = current

        let mutated = libraryCache.mutateBook(uniqueId: current.uniqueId) { updated in
            updated.epubLocator = jsonString
            updated.ebookProgress = ebookProgress
            updated.currentTime = clampedAudioTime
            updated.duration = result.totalDuration
            updated.lastUpdate = now
        }
        if let mutated {
            syncBook = mutated
        }

        if let sourceStableId = current.readAloudSourceStableId,
            let source = libraryCache.bookInMemory(stableId: sourceStableId),
            source.readAloudSourceStableId == nil
        {
            let mutatedSource = libraryCache.mutateBook(stableId: sourceStableId) { updated in
                updated.epubLocator = jsonString
                updated.ebookProgress = ebookProgress
                updated.lastUpdate = now
            }
            if let mutatedSource {
                syncBook = mutatedSource
            }
        }

        EbookLinkStore.shared.saveLinks()

        var currentPersistedBook = current
        currentPersistedBook.epubLocator = jsonString
        currentPersistedBook.ebookProgress = ebookProgress
        currentPersistedBook.currentTime = clampedAudioTime
        currentPersistedBook.duration = result.totalDuration
        currentPersistedBook.lastUpdate = now
        var persistedBook = syncBook
        persistedBook.epubLocator = jsonString
        persistedBook.ebookProgress = ebookProgress
        persistedBook.lastUpdate = now
        let capturedCurrentBook = currentPersistedBook
        let capturedBook = persistedBook

        positionSyncTask?.cancel()
        positionSyncGeneration += 1
        let syncGeneration = positionSyncGeneration
        positionSyncTask = Task { @MainActor in
            var backgroundTask: UIBackgroundTaskIdentifier = .invalid
            backgroundTask = UIApplication.shared.beginBackgroundTask {
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
            }
            defer {
                if self.positionSyncGeneration == syncGeneration {
                    self.positionSyncTask = nil
                }
                if backgroundTask != .invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                    backgroundTask = .invalid
                }
            }
            guard !Task.isCancelled, self.positionSyncGeneration == syncGeneration else { return }
            await bookRepository.updateEbookProgress(
                uniqueId: capturedCurrentBook.uniqueId,
                ebookProgress: ebookProgress,
                epubLocator: jsonString,
                isFinished: ebookProgress >= 0.99,
                lastUpdate: now
            )
            if capturedBook.uniqueId != capturedCurrentBook.uniqueId {
                await bookRepository.updateEbookProgress(
                    uniqueId: capturedBook.uniqueId,
                    ebookProgress: ebookProgress,
                    epubLocator: jsonString,
                    isFinished: ebookProgress >= 0.99,
                    lastUpdate: now
                )
            }

            guard !Task.isCancelled, self.positionSyncGeneration == syncGeneration else { return }

            if capturedCurrentBook.isStorytellerReadAloud {
                do {
                    try await StorytellerPositionSyncService.shared.submit(
                        book: capturedCurrentBook,
                        locatorJSON: jsonString,
                        observedAt: now
                    )
                } catch is CancellationError {
                    return
                } catch {
                    AppLogger.sync.error(
                        "Storyteller read-aloud CarPlay progress push failed for \(capturedBook.title): \(error.localizedDescription)"
                    )
                }
            } else {
                await SyncCoordinator.shared.pushProgress(book: capturedBook, domain: .ebook)
            }
            guard !Task.isCancelled, self.positionSyncGeneration == syncGeneration else { return }

            await LinkedBookProgressCoordinator.shared.recordEbookProgress(
                book: capturedCurrentBook,
                progression: ebookProgress,
                exactAudioTime: clampedAudioTime,
                exactAudioDuration: result.totalDuration,
                observedAt: now,
                authoritative: authoritative
            )
        }
    }

    private func activeBookMatches(_ book: Book) -> Bool {
        guard activeProviderId == book.providerId else { return false }
        return activeBookUniqueId == book.uniqueId
            || activeReadAloudSourceStableId == book.stableId
            || book.readAloudSourceStableId == activeBookStableId
    }

    func audioPosition(forLocatorJSON locatorJSON: String?, result: OverlayAudioResult) -> TimeInterval? {
        guard let locatorJSON else { return nil }
        return result.timeline.resolveEPUB3Locator(locatorJSON: locatorJSON)?.audioTime
    }

    private static func overlayHrefMatches(_ smilHref: String, _ readiumHref: String) -> Bool {
        if smilHref == readiumHref { return true }

        let a = smilHref.hasPrefix("/") ? String(smilHref.dropFirst()) : smilHref
        let b = readiumHref.hasPrefix("/") ? String(readiumHref.dropFirst()) : readiumHref
        if a == b { return true }
        if a.hasSuffix(b) || b.hasSuffix(a) { return true }

        let fileA = (a as NSString).lastPathComponent
        let fileB = (b as NSString).lastPathComponent
        return fileA == fileB && !fileA.isEmpty
    }

    func clipIndex(forAudioTime audioTime: TimeInterval, result: OverlayAudioResult) -> Int? {
        result.timeline.clipIndex(atAudioTime: audioTime)
    }

    private func probeAudioDuration(url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)
            return seconds.isFinite ? seconds : nil
        } catch {
            AppLogger.library.warning(
                "Could not probe duration \(DiagnosticLogSanitizer.fileDescriptor(for: url)): \(error)"
            )
            return nil
        }
    }

    private func resolveEbookFile(for book: Book) -> URL? {
        LocalEbookImporter.shared.resolveEbookForOverlay(book: book)
    }

    private func loadIndexedAudioTracks(for book: Book, epubFileURL: URL) -> OverlayAudioResult? {
        guard let index = loadReadAloudIndex(for: book, epubFileURL: epubFileURL),
            !index.clips.isEmpty
        else { return nil }

        var sources: [String] = []
        var seen = Set<String>()
        for clip in index.clips where seen.insert(clip.audioSrc).inserted {
            sources.append(clip.audioSrc)
        }

        guard let cachedAudio = cachedReadAloudAudioFiles(for: book, sources: sources) else {
            return nil
        }

        let timeline = MediaOverlayTimeline(
            clips: index.clips,
            audioDurationsBySource: index.audioDurationsBySource
        )
        guard
            let result = overlayResult(
                timeline: timeline,
                audioFilesBySource: cachedAudio.filesBySource,
                chapters: index.chapters,
                audioDirectory: cachedAudio.directory
            )
        else {
            return nil
        }

        AppLogger.library.debug(
            "MediaOverlayPlayback: loaded indexed read-aloud timeline clips=\(index.clips.count) bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
        )
        return result
    }

    private func overlayResult(
        timeline: MediaOverlayTimeline,
        audioFilesBySource: [String: URL],
        chapters: [Chapter],
        audioDirectory: URL
    ) -> OverlayAudioResult? {
        var tracks = [AudioTrackInfo]()
        for (index, file) in timeline.audioFiles.enumerated() {
            guard let url = audioFilesBySource[file.source] else { return nil }
            tracks.append(
                AudioTrackInfo(
                    index: index,
                    startOffset: file.start,
                    duration: file.duration,
                    contentUrl: url.absoluteString,
                    mimeType: guessMimeType(for: url)
                )
            )
        }

        guard !tracks.isEmpty else { return nil }
        return OverlayAudioResult(
            tracks: tracks,
            totalDuration: timeline.totalAudioDuration,
            chapters: chapters,
            timeline: timeline,
            audioDirectory: audioDirectory
        )
    }

    private func readAloudIndexURL(for book: Book) -> URL {
        LocalStorageManager.shared.bookAudioDirectory(for: book.downloadKey)
            .appendingPathComponent("readaloud-index.json", isDirectory: false)
    }

    private func readAloudFileSignature(for epubFileURL: URL) -> String {
        let values = try? epubFileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = Int((values?.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        return "\(epubFileURL.lastPathComponent)-\(size)-\(modified)"
    }

    private func loadReadAloudIndex(for book: Book, epubFileURL: URL) -> ReadAloudIndex? {
        let url = readAloudIndexURL(for: book)
        guard let data = try? Data(contentsOf: url),
            let index = try? JSONDecoder().decode(ReadAloudIndex.self, from: data),
            index.schemaVersion == 1,
            index.fileSignature == readAloudFileSignature(for: epubFileURL)
        else {
            return nil
        }
        return index
    }

    private func saveReadAloudIndexIfPersistent(
        for book: Book,
        epubFileURL: URL,
        clips: [AudioOverlayClip],
        audioDurationsBySource: [String: TimeInterval],
        chapters: [Chapter],
        audioDirectory: URL
    ) {
        let persistentDirectory = LocalStorageManager.shared.bookAudioDirectory(for: book.downloadKey)
        guard audioDirectory.standardizedFileURL.path == persistentDirectory.standardizedFileURL.path,
            !clips.isEmpty
        else { return }

        let index = ReadAloudIndex(
            schemaVersion: 1,
            fileSignature: readAloudFileSignature(for: epubFileURL),
            clips: clips,
            audioDurationsBySource: audioDurationsBySource,
            chapters: chapters
        )

        do {
            try FileManager.default.createDirectory(at: persistentDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(index)
            try data.write(to: readAloudIndexURL(for: book), options: .atomic)
            AppLogger.library.debug(
                "MediaOverlayPlayback: saved read-aloud index clips=\(clips.count) bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
        } catch {
            AppLogger.library.warning(
                "MediaOverlayPlayback: failed to save read-aloud index bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
            )
        }
    }

    private func cachedReadAloudAudioFiles(
        for book: Book,
        sources: [String]
    ) -> (directory: URL, filesBySource: [String: URL])? {
        guard !sources.isEmpty else { return nil }

        let directory = LocalStorageManager.shared.bookAudioDirectory(for: book.downloadKey)
        let files =
            ((try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? [])
            .filter { AudiobookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard files.count == sources.count else { return nil }

        var filesBySource: [String: URL] = [:]
        for source in sources {
            let filename = EPUB3SMILParser.localAudioFilename(for: source)
            if let match = files.first(where: { $0.lastPathComponent == filename }) {
                filesBySource[source] = match
            }
        }

        if filesBySource.count == sources.count {
            return (directory, filesBySource)
        }

        let sortedSources = sources.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        filesBySource = Dictionary(uniqueKeysWithValues: zip(sortedSources, files))
        return filesBySource.count == sources.count ? (directory, filesBySource) : nil
    }

    private func guessMimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "m4b", "mp4": return "audio/mp4"
        case "ogg", "oga": return "audio/ogg"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        default: return "audio/mpeg"
        }
    }

    private func buildOverlayChapters(
        publication: Publication,
        clips: [AudioOverlayClip],
        clipGlobalTimes: [(start: TimeInterval, end: TimeInterval)]
    ) async -> [Chapter] {
        guard clips.count == clipGlobalTimes.count else { return [] }

        let toc = (try? await publication.tableOfContents().get()) ?? []
        let tocEntries = flattenTOC(toc)
        var chapters: [Chapter] = []

        for (readingOrderIndex, link) in publication.readingOrder.enumerated() {
            let href = link.href
            let matchingIndices = clips.indices.filter { Self.overlayHrefMatches(clips[$0].textHref, href) }
            guard !matchingIndices.isEmpty else { continue }

            let start = matchingIndices.map { clipGlobalTimes[$0].start }.min() ?? 0
            let end = matchingIndices.map { clipGlobalTimes[$0].end }.max() ?? start
            guard end > start else { continue }

            let title = titleForChapter(href: href, linkTitle: link.title, tocEntries: tocEntries, fallbackIndex: chapters.count)
            chapters.append(
                Chapter(
                    id: "overlay-\(readingOrderIndex)-\(href)",
                    start: start,
                    end: end,
                    title: title,
                    index: chapters.count
                )
            )
        }

        return chapters
    }

    private func flattenTOC(_ links: [ReadiumShared.Link]) -> [(href: String, title: String)] {
        links.flatMap { link in
            let cleaned = link.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = cleaned?.isEmpty == false ? cleaned ?? "Chapter" : "Chapter"
            return [(link.href, title)] + flattenTOC(link.children)
        }
    }

    private func titleForChapter(
        href: String,
        linkTitle: String?,
        tocEntries: [(href: String, title: String)],
        fallbackIndex: Int
    ) -> String {
        let baseHref = href.components(separatedBy: "#").first ?? href
        if let tocTitle = tocEntries.first(where: { entry in
            let entryHref = entry.href.components(separatedBy: "#").first ?? entry.href
            return Self.overlayHrefMatches(entryHref, baseHref)
        })?.title.trimmingCharacters(in: .whitespacesAndNewlines),
            !tocTitle.isEmpty
        {
            return tocTitle
        }

        if let linkTitle = linkTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !linkTitle.isEmpty {
            return linkTitle
        }

        return "Chapter \(fallbackIndex + 1)"
    }

    enum OverlayPlaybackError: LocalizedError {
        case noEbookFile
        case invalidURL(String)
        case noOverlayClips
        case unsupportedPlatform

        var errorDescription: String? {
            switch self {
            case .noEbookFile: return "Ebook file not found on this device. Download it first."
            case .invalidURL(let p): return "Invalid ebook path: \(p)"
            case .noOverlayClips: return "This ebook has no audio overlay content."
            case .unsupportedPlatform: return "Read-aloud playback is unavailable on this device."
            }
        }
    }
}
