#if os(iOS)
import Combine
import Foundation
import UIKit
import WatchConnectivity

@MainActor
final class WatchSessionBridge: NSObject {
    static let shared = WatchSessionBridge(
        providerResolver: AppState.shared.providerConnections,
        connectionAccess: AppState.shared.providerConnections,
        bookQuerying: AppState.shared.bookStore,
        libraryCache: AppState.shared.libraryCache
    )

    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false
    private var lastPayload = WatchNowPlayingPayload.empty
    private var lastContextPush = Date.distantPast
    private var watchABSSessions: [String: String] = [:]
    private let providerResolver: any LibraryProviderResolving
    private let connectionAccess: any ProviderConnectionAccessing
    private let bookQuerying: any BookQuerying
    private let libraryCache: LibraryBookCache
    private let playback: any PlaybackControlling

    private init(
        providerResolver: any LibraryProviderResolving,
        connectionAccess: any ProviderConnectionAccessing,
        bookQuerying: any BookQuerying,
        libraryCache: LibraryBookCache,
        playback: any PlaybackControlling = ActivePlayback.controller
    ) {
        self.providerResolver = providerResolver
        self.connectionAccess = connectionAccess
        self.bookQuerying = bookQuerying
        self.libraryCache = libraryCache
        self.playback = playback
        super.init()
    }

    func start() {
        guard !hasStarted, WCSession.isSupported() else { return }
        hasStarted = true

        let session = WCSession.default
        session.delegate = self
        session.activate()

        playback.snapshots
        .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
        .sink { [weak self] _ in self?.pushNowPlaying() }
        .store(in: &cancellables)
    }

    private func currentPayload() -> WatchNowPlayingPayload {
        let playback = playback.snapshot
        let player = PlayerViewModel.shared
        let book = playback.currentBook ?? player.currentBook
        let position = playback.duration > 0 ? playback.position : player.progress
        let duration = playback.duration > 0 ? playback.duration : (book?.duration ?? player.duration)
        let chapter = book?.chapters?.last { position >= $0.start && position < $0.end }?.title ?? ""
        let sleep = player.sleepTimerRemainingSeconds
        return WatchNowPlayingPayload(
            hasBook: book != nil,
            stableId: book?.stableId ?? "",
            title: book?.title ?? "",
            author: book?.author ?? "",
            chapterTitle: chapter,
            isPlaying: playback.isPlaying,
            position: position,
            duration: duration,
            speed: playback.playbackSpeed,
            skipForward: Int(player.preferences.skipForwardAmount),
            skipBackward: Int(player.preferences.skipBackwardAmount),
            sleepRemaining: sleep > 0 ? sleep : nil,
            sentAt: Date()
        )
    }

    private func pushNowPlaying(force: Bool = false) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }

        let payload = currentPayload()

        var comparable = payload
        comparable.position = lastPayload.position
        comparable.sentAt = lastPayload.sentAt
        if payload.sleepRemaining != nil, lastPayload.sleepRemaining != nil {
            comparable.sleepRemaining = lastPayload.sleepRemaining
        }
        let elapsed = payload.sentAt.timeIntervalSince(lastPayload.sentAt)
        let expectedPosition = lastPayload.position + (lastPayload.isPlaying ? elapsed * lastPayload.speed : 0)
        let positionJumped = abs(payload.position - expectedPosition) > 5
        let stateChanged = comparable != lastPayload || positionJumped
        let needsResync = Date().timeIntervalSince(lastContextPush) > 15
        guard force || stateChanged || needsResync else { return }

        lastPayload = payload
        lastContextPush = Date()
        let envelope = WatchWire.envelope(.nowPlaying, payload)
        try? session.updateApplicationContext(envelope)
        if session.isReachable {
            session.sendMessage(envelope, replyHandler: nil, errorHandler: nil)
        }
    }

    private func handle(_ message: [String: Any], reply: (@Sendable ([String: Any]) -> Void)?) async {
        guard let kind = WatchWire.kind(of: message) else {
            reply?(WatchWire.replyError("unknown message"))
            return
        }

        switch kind {
        case .requestNowPlaying:
            reply?(WatchWire.reply(currentPayload()))

        case .requestLibrary:
            reply?(WatchWire.reply(await buildSnapshot()))

        case .requestSearch:
            guard let request = WatchWire.payload(WatchSearchRequest.self, from: message) else {
                reply?(WatchWire.replyError("bad search request"))
                return
            }
            let books = await bookQuerying.searchBooks(query: request.query, limit: 40)
            reply?(WatchWire.reply(WatchSearchResults(items: books.filter { $0.mediaType != .ebook }.map(Self.summary))))

        case .requestDescriptor:
            guard let request = WatchWire.payload(WatchDescriptorRequest.self, from: message) else {
                reply?(WatchWire.replyError("bad descriptor request"))
                return
            }
            do {
                let descriptor = try await buildDescriptor(stableId: request.stableId)
                reply?(WatchWire.reply(descriptor))
            } catch {
                reply?(WatchWire.replyError(error.localizedDescription))
            }

        case .requestCover:
            guard let request = WatchWire.payload(WatchCoverRequest.self, from: message) else {
                reply?(WatchWire.replyError("bad cover request"))
                return
            }
            let jpeg = await coverJPEG(stableId: request.stableId, maxPixels: request.maxPixels)
            reply?(WatchWire.reply(WatchCoverReply(jpeg: jpeg)))

        case .requestPosition:
            guard let request = WatchWire.payload(WatchDescriptorRequest.self, from: message),
                let book = await findBook(stableId: request.stableId),
                let stored = BookProgressStore.shared.loadProgress(for: book)
            else {
                reply?(WatchWire.replyError("no stored position"))
                return
            }
            reply?(
                WatchWire.reply(
                    WatchPositionReply(
                        position: stored.progress,
                        updatedAt: Date(timeIntervalSince1970: stored.lastUpdated)
                    )
                )
            )

        case .reportProgress:
            if let report = WatchWire.payload(WatchProgressReport.self, from: message) {
                await apply(report)
            }
            reply?(["ok": true])

        case .command:
            if let command = WatchWire.payload(WatchCommandPayload.self, from: message) {
                await execute(command)
            }
            reply?(["ok": true])

        case .nowPlaying:
            reply?(["ok": true])
        }
    }

    private static func summary(_ book: Book) -> WatchBookSummary {
        let stored = BookProgressStore.shared.loadProgress(for: book)
        return WatchBookSummary(
            stableId: book.stableId,
            title: String(book.title.prefix(120)),
            author: String((book.author ?? "").prefix(80)),
            duration: stored?.duration ?? book.duration ?? 0,
            position: stored?.progress ?? book.currentTime,
            isFinished: book.isFinished,
            isPodcastEpisode: book.isPodcastEpisode,
            podcastName: book.podcastName.map { String($0.prefix(80)) }
        )
    }

    private func buildSnapshot() async -> WatchLibrarySnapshot {
        let store = bookQuerying
        let continueBooks = await store.continueListeningBooks(limit: 24).filter { $0.mediaType != .ebook }
        let recentBooks = await store.pagedBooks(offset: 0, limit: 24, mediaType: AppMediaType.audiobook.rawValue)
        var podcastBooks = await store.pagedBooks(offset: 0, limit: 30, mediaType: AppMediaType.podcast.rawValue)

        let known = Set(podcastBooks.map(\.stableId))
        let rssEpisodes = BookProgressStore.shared.loadRecentlyPlayed()
            .filter { $0.isPodcastEpisode && !known.contains($0.stableId) }
        podcastBooks = rssEpisodes + podcastBooks
        return WatchLibrarySnapshot(
            continueItems: continueBooks.map(Self.summary),
            recentItems: recentBooks.map(Self.summary),
            podcastItems: podcastBooks.prefix(30).map(Self.summary),
            generatedAt: Date()
        )
    }

    private func findBook(stableId: String) async -> Book? {
        if let book = await bookQuerying.book(stableId: stableId) {
            return book
        }
        return BookProgressStore.shared.loadRecentlyPlayed().first { $0.stableId == stableId }
    }

    private func buildDescriptor(stableId: String) async throws -> WatchPlaybackDescriptor {
        guard let book = await findBook(stableId: stableId) else {
            throw WatchBridgeError.bookNotFound
        }
        guard book.mediaType != .ebook else {
            throw WatchBridgeError.notAudio
        }

        let position = BookProgressStore.shared.loadProgress(for: book)?.progress ?? book.currentTime

        if book.isPodcastEpisode, providerResolver.provider(for: book) == nil {
            guard let urlString = book.partKey, let url = URL(string: urlString), !url.isFileURL else {
                throw WatchBridgeError.noStreamURL
            }
            return WatchPlaybackDescriptor(
                stableId: book.stableId,
                title: book.title,
                author: book.podcastName ?? book.author ?? "",
                duration: book.duration ?? 0,
                startTime: position,
                headers: [:],
                tracks: [
                    WatchTrackPayload(
                        index: 0,
                        url: url.absoluteString,
                        duration: book.duration ?? 0,
                        startOffset: 0,
                        fileExtension: url.pathExtension.isEmpty ? "mp3" : url.pathExtension
                    )
                ],
                chapters: (book.chapters ?? []).map(Self.chapterPayload)
            )
        }

        guard let provider = providerResolver.capability(PlaybackSessionProvider.self, for: book) else {
            throw WatchBridgeError.noProvider
        }
        let headers = provider.getStreamingHeaders()
        closeStaleWatchSession(for: book)

        if let session = try? await provider.startPlaybackSession(for: book) {
            if book.source == .audiobookshelf {
                watchABSSessions[book.stableId] = session.sessionId
            }
            let tracks = session.audioTracks
                .sorted { $0.startOffset < $1.startOffset }
                .compactMap { track -> WatchTrackPayload? in
                    guard var url = URL(string: track.contentUrl), !url.isFileURL else { return nil }
                    if book.source == .audiobookshelf, let token = provider.connection.token {
                        url = Self.appendingToken(url, token: token)
                    }
                    return WatchTrackPayload(
                        index: track.index,
                        url: url.absoluteString,
                        duration: track.duration,
                        startOffset: track.startOffset,
                        fileExtension: Self.fileExtension(mimeType: track.mimeType, url: url)
                    )
                }
            if !tracks.isEmpty {
                let chapters = session.chapters.isEmpty ? (book.chapters ?? []) : session.chapters
                let duration = tracks.map(\.duration).reduce(0, +)
                let startTime = (session.serverCurrentTime ?? 0) > 0 ? session.serverCurrentTime! : position
                return WatchPlaybackDescriptor(
                    stableId: book.stableId,
                    title: book.title,
                    author: book.author ?? "",
                    duration: duration > 0 ? duration : (book.duration ?? 0),
                    startTime: startTime,
                    headers: headers,
                    tracks: tracks,
                    chapters: chapters.map(Self.chapterPayload)
                )
            }
        }

        var streamURL = provider.getAudioURL(for: book)
        if streamURL == nil {
            streamURL = try? await PlayerViewModel.shared.resolveStreamURL(for: book)
        }
        guard var url = streamURL, !url.isFileURL else {
            throw WatchBridgeError.noStreamURL
        }
        if book.source == .audiobookshelf, let token = provider.connection.token {
            url = Self.appendingToken(url, token: token)
        }
        return WatchPlaybackDescriptor(
            stableId: book.stableId,
            title: book.title,
            author: book.author ?? "",
            duration: book.duration ?? 0,
            startTime: position,
            headers: headers,
            tracks: [
                WatchTrackPayload(
                    index: 0,
                    url: url.absoluteString,
                    duration: book.duration ?? 0,
                    startOffset: 0,
                    fileExtension: url.pathExtension.isEmpty ? "m4b" : url.pathExtension
                )
            ],
            chapters: (book.chapters ?? []).map(Self.chapterPayload)
        )
    }

    private func closeStaleWatchSession(for book: Book) {
        guard book.source == .audiobookshelf,
            let sessionId = watchABSSessions.removeValue(forKey: book.stableId),
            let backendId = book.backendId,
            let backend = connectionAccess.backend(id: backendId)
        else { return }
        let position = BookProgressStore.shared.loadProgress(for: book)?.progress ?? book.currentTime
        let duration = book.duration ?? 0
        Task.detached(priority: .utility) {
            try? await AudiobookshelfService.shared.closePlaySession(
                sessionId: sessionId,
                currentTime: position,
                duration: duration,
                backend: backend
            )
        }
    }

    private static func chapterPayload(_ chapter: Chapter) -> WatchChapterPayload {
        WatchChapterPayload(index: chapter.index, title: chapter.title, start: chapter.start, end: chapter.end)
    }

    private static func appendingToken(_ url: URL, token: String) -> URL {
        guard !token.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        guard !items.contains(where: { $0.name == "token" }) else { return url }
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        return components.url ?? url
    }

    private static func fileExtension(mimeType: String, url: URL) -> String {
        if !url.pathExtension.isEmpty { return url.pathExtension }
        switch mimeType.lowercased() {
        case "audio/mpeg": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/x-m4b": return "m4a"
        case "audio/aac": return "aac"
        case "audio/flac": return "flac"
        case "audio/ogg": return "ogg"
        default: return "m4a"
        }
    }

    private func coverJPEG(stableId: String, maxPixels: Int) async -> Data? {
        guard let book = await findBook(stableId: stableId), let coverURL = book.coverURL else { return nil }

        let image: UIImage?
        if let cached = await DiskImageCache.shared.image(for: coverURL) {
            image = cached
        } else if coverURL.isFileURL {
            image = UIImage(contentsOfFile: coverURL.path)
        } else {
            var request = URLRequest(url: coverURL)
            for (key, value) in CachedAsyncCoverImage.authHeaders(for: book) {
                request.setValue(value, forHTTPHeaderField: key)
            }
            if let data = try? await URLSession.shared.data(for: request).0 {
                image = UIImage(data: data)
            } else {
                image = nil
            }
        }
        guard let image else { return nil }

        let side = CGFloat(max(64, min(maxPixels, 480)))
        let scale = min(side / max(image.size.width, 1), side / max(image.size.height, 1), 1)
        let canvas = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: canvas))
        }
        var jpeg = resized.jpegData(compressionQuality: 0.75)

        if let data = jpeg, data.count > 55_000 {
            jpeg = resized.jpegData(compressionQuality: 0.45)
        }
        return jpeg
    }

    private func apply(_ report: WatchProgressReport) async {
        let playback = playback.snapshot
        if playback.isPlaying, playback.currentBook?.stableId == report.stableId {
            return
        }
        guard let book = await findBook(stableId: report.stableId) else { return }

        if let stored = BookProgressStore.shared.loadProgress(for: book),
            stored.lastUpdated > report.timestamp.timeIntervalSince1970
        {
            return
        }

        BookProgressStore.shared.saveProgress(for: book, progress: report.position, duration: report.duration, at: report.timestamp)
        BookProgressStore.shared.saveRecentlyPlayed(book, date: report.timestamp)
        libraryCache.mutateBook(uniqueId: book.uniqueId) {
            $0.currentTime = report.position
            $0.lastUpdate = report.timestamp
            $0.isFinished = report.isFinished
        }

        var updated = book
        updated.currentTime = report.position
        updated.lastUpdate = report.timestamp
        updated.isFinished = report.isFinished
        await SyncCoordinator.shared.pushProgress(
            book: updated,
            forceImmediate: true,
            domain: .audiobook
        )
    }

    private func execute(_ command: WatchCommandPayload) async {
        let player = PlayerViewModel.shared
        switch command.action {
        case .play:
            guard let book = await findBook(stableId: command.value) else { return }
            EnveEngine.shared.playback.play(book, presentPlayer: false)
        case .toggle:
            player.togglePlay()
        case .pause:
            player.pause()
        case .skipForward:
            player.skipForward()
        case .skipBackward:
            player.skipBackward()
        case .speed:
            player.setPlaybackSpeed(command.seconds)
        case .sleep:
            if command.seconds == -1 {
                player.stopSleepTimer()
            } else if command.seconds == -2 {
                player.setSleepTimerToEndOfChapter()
            } else {
                player.startSleepTimer(minutes: Int(command.seconds))
            }
        }
        pushNowPlaying(force: true)
    }
}

private enum WatchBridgeError: LocalizedError {
    case bookNotFound
    case notAudio
    case noProvider
    case noStreamURL

    var errorDescription: String? {
        switch self {
        case .bookNotFound: return "Book not found in the library."
        case .notAudio: return "This title has no audio edition."
        case .noProvider: return "The book's server connection is unavailable."
        case .noStreamURL: return "Could not resolve a stream URL."
        }
    }
}

extension WatchSessionBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in WatchSessionBridge.shared.pushNowPlaying() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in WatchSessionBridge.shared.pushNowPlaying() }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let payload = UncheckedSendableBox(message)
        Task { @MainActor in
            await WatchSessionBridge.shared.handle(payload.value, reply: nil)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let payload = UncheckedSendableBox(message)
        let reply = UncheckedSendableBox(replyHandler)
        Task { @MainActor in
            await WatchSessionBridge.shared.handle(payload.value) { reply.value($0) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let payload = UncheckedSendableBox(userInfo)
        Task { @MainActor in
            await WatchSessionBridge.shared.handle(payload.value, reply: nil)
        }
    }
}

private nonisolated struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}
#endif
