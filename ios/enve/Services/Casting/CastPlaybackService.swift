#if os(iOS) && canImport(GoogleCast)
import Foundation
@preconcurrency import GoogleCast
import Logging
import MediaPlayer

enum CastConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(deviceName: String)
}

@MainActor
@Observable
final class CastPlaybackService: NSObject {
    private struct LoadedMedia {
        var book: Book
        let provider: (any PlaybackSessionProvider)?
        let sessionId: String?
        let plan: CastMediaPlan
    }

    private struct Intent {
        var autoplay: Bool
        var seekOverride: TimeInterval?
        var rateOverride: Double?
    }

    private struct Preparing {
        let generation: Int
        let book: Book
        let position: TimeInterval
        var intent: Intent
        let localResume: Bool
    }

    private struct PendingLoad {
        let generation: Int
        let media: LoadedMedia
        let requestedAutoplay: Bool
        var intent: Intent
        let localResume: Bool
        let request: GCKRequest
    }

    private struct ActiveCast {
        var media: LoadedMedia
        var position: TimeInterval
        var isPlaying = false
        var isBuffering = true
        var trackIndex: Int
        var listenedSinceSync: TimeInterval = 0
        var lastTickAt = Date()
        var lastLocalSaveAt = Date.distantPast
        var lastServerPushAt = Date()
        var reportedStart = false
    }

    private static let loadTimeout: Duration = .seconds(20)
    private static let receiverRateRange: ClosedRange<Double> = 0.5...2.0

    private(set) var connection: CastConnectionState = .disconnected
    private(set) var endedSnapshot: PlaybackSnapshot?

    @ObservationIgnored var onStateChange: (() -> Void)?
    @ObservationIgnored var onEvent: ((PlaybackEvent) -> Void)?
    @ObservationIgnored var resumeLocally: ((Book, TimeInterval) -> Void)?

    @ObservationIgnored private unowned let profileSession: ProfileSession
    @ObservationIgnored private let localPlayback: PlaybackManager
    @ObservationIgnored private let progressQueue = PerBookSerialQueue()
    @ObservationIgnored private var sessionManager: GCKSessionManager?
    @ObservationIgnored private weak var observedClient: GCKRemoteMediaClient?
    @ObservationIgnored private var hasUserIntent = false
    @ObservationIgnored private var preparing: Preparing?
    @ObservationIgnored private var pending: PendingLoad?
    @ObservationIgnored private var active: ActiveCast?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var operations: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var isRetired = false
    @ObservationIgnored private var acceptsOperations = true

    init(profileSession: ProfileSession, localPlayback: PlaybackManager) {
        self.profileSession = profileSession
        self.localPlayback = localPlayback
        super.init()
        Self.configureIfNeeded()
        let manager = GCKCastContext.sharedInstance().sessionManager
        sessionManager = manager
        manager.add(self)
        if manager.hasConnectedCastSession() { releaseRestoredSession() }
    }

    private static func configureIfNeeded() {
        guard !GCKCastContext.isSharedInstanceInitialized() else { return }
        let options = GCKCastOptions(
            discoveryCriteria: GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        )
        options.startDiscoveryAfterFirstTapOnCastButton = true
        options.physicalVolumeButtonsWillControlDeviceVolume = true
        options.stopReceiverApplicationWhenEndingSession = true
        options.suspendSessionsWhenBackgrounded = false
        GCKCastContext.setSharedInstanceWith(options)
    }

    var isConnected: Bool {
        if case .connected = connection { return hasUserIntent }
        return false
    }

    var ownsPlayback: Bool { preparing != nil || pending != nil || active != nil }

    var snapshot: PlaybackSnapshot? {
        if let preparing {
            return PlaybackSnapshot(
                currentBook: preparing.book, isPlaying: false, position: preparing.intent.seekOverride ?? preparing.position,
                duration: preparing.book.duration ?? 0, playbackSpeed: playbackRate, volume: deviceVolume,
                isLoaded: false, isLoading: true, isOverlayPlaybackActive: false, errorDescription: nil
            )
        }
        if let pending {
            return PlaybackSnapshot(
                currentBook: pending.media.book, isPlaying: false,
                position: pending.intent.seekOverride ?? pending.media.plan.startPosition,
                duration: duration(of: pending.media), playbackSpeed: playbackRate, volume: deviceVolume,
                isLoaded: false, isLoading: true, isOverlayPlaybackActive: false, errorDescription: nil
            )
        }
        guard let active else { return nil }
        return PlaybackSnapshot(
            currentBook: active.media.book, isPlaying: active.isPlaying, position: active.position,
            duration: duration(of: active.media), playbackSpeed: playbackRate, volume: deviceVolume,
            isLoaded: true, isLoading: active.isBuffering && active.isPlaying,
            isOverlayPlaybackActive: false, errorDescription: nil
        )
    }

    var livePosition: TimeInterval? {
        guard let active, let client = observedClient, client.mediaStatus != nil else { return nil }
        return active.media.plan.globalPosition(trackIndex: active.trackIndex, localPosition: client.approximateStreamPosition())
    }

    private var currentSession: GCKCastSession? { sessionManager?.currentCastSession }

    private var playbackRate: Double {
        Double(observedClient?.mediaStatus?.playbackRate ?? Float(localPlayback.playbackSpeed))
    }

    private var deviceVolume: Double { Double(currentSession?.currentDeviceVolume ?? 1) }

    func play(_ book: Book, from startPosition: TimeInterval?) {
        guard !isRetired else { return }
        guard isConnected else {
            reportFailure(.notConnected, title: book.title)
            return
        }
        if let active, active.media.book.stableId == book.stableId, preparing == nil, pending == nil {
            if let startPosition { seek(to: startPosition) }
            play()
            return
        }
        startLoad(book: book, startPosition: startPosition, autoplay: true, localResume: false)
    }

    private func handOffLocalPlayback() {
        guard !ownsPlayback, let book = localPlayback.currentBook, localPlayback.hasActivePlayer,
            book.mediaType == .audiobook, !localPlayback.isOverlayPlaybackActive
        else { return }
        let position = localPlayback.livePosition ?? localPlayback.currentTime
        let wasPlaying = localPlayback.isPlaying
        if wasPlaying { localPlayback.pause() }
        startLoad(book: book, startPosition: position, autoplay: wasPlaying, localResume: wasPlaying)
    }

    private func startLoad(book: Book, startPosition: TimeInterval?, autoplay: Bool, localResume: Bool) {
        generation &+= 1
        let generation = generation
        loadTask?.cancel()
        preparing = nil
        abandonPending(stopReceiver: false)
        endedSnapshot = nil
        let book = profileSession.appState.libraryCache.book(uniqueId: book.uniqueId) ?? book
        preparing = Preparing(
            generation: generation, book: book, position: startPosition ?? book.currentTime,
            intent: Intent(autoplay: autoplay), localResume: localResume
        )
        notifyChange()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let media = try await prepareMedia(for: book, startPosition: startPosition)
                guard isCurrent(generation), let prepared = preparing, prepared.generation == generation else {
                    discardPreparation(generation: generation)
                    closeServerSession(of: media, position: media.plan.startPosition)
                    return
                }
                preparing = nil
                try send(media, intent: prepared.intent, localResume: prepared.localResume, generation: generation)
                try await Task.sleep(for: Self.loadTimeout)
                if pending?.generation == generation { failPending(.loadFailed, stopReceiver: true) }
            } catch is CancellationError {
                discardPreparation(generation: generation)
            } catch {
                guard !isRetired, generation == self.generation else { return }
                let rollBack = preparing?.localResume ?? localResume
                preparing = nil
                if pending?.generation == generation {
                    failPending(error as? CastPlaybackError ?? .loadFailed, stopReceiver: false)
                } else {
                    if rollBack, localPlayback.currentBook != nil { localPlayback.play() }
                    reportFailure(error as? CastPlaybackError ?? .loadFailed, title: book.title)
                    notifyChange()
                }
            }
        }
    }

    private func discardPreparation(generation: Int) {
        guard let stale = preparing, stale.generation == generation else { return }
        preparing = nil
        if !isRetired, stale.localResume, localPlayback.currentBook != nil { localPlayback.play() }
        notifyChange()
    }

    private func prepareMedia(for book: Book, startPosition: TimeInterval?) async throws -> LoadedMedia {
        let provider = profileSession.providerConnections.capability(PlaybackSessionProvider.self, for: book)
        guard let provider, !provider.connection.isArchived else {
            guard book.isPodcastEpisode, let partKey = book.partKey else { throw CastPlaybackError.localMediaUnsupported }
            let track = AudioTrackInfo(index: 0, startOffset: 0, duration: book.duration ?? 0, contentUrl: partKey, mimeType: "audio/mpeg")
            let resume = startPosition ?? CastResumePolicy.resumePosition(
                local: localProgressSamples(for: book), server: nil, tolerance: AppConstants.Playback.resumeTimeTolerance)
            let plan = try CastMediaPlan(tracks: [track], resumeAt: resume, streamingHeaders: [:])
            return LoadedMedia(book: book, provider: nil, sessionId: nil, plan: plan)
        }

        var serverProgress: CastProgressSample?
        if startPosition == nil, profileSession.serverSyncEnabled,
            let puller = provider as? any AudiobookProgressPulling,
            let result = try? await PlaybackStartupDeadline.run(seconds: 8, operation: {
                try await puller.fetchAudiobookProgress(for: book)
            })
        {
            let duration = book.duration ?? 0
            let position = result.positionSeconds > 0 ? result.positionSeconds : (duration > 0 ? result.percentage * duration : 0)
            serverProgress = CastProgressSample(position: position, updatedAt: result.updatedAt ?? .distantPast)
        }
        try Task.checkCancellation()

        let session = try await PlaybackStartupDeadline.run(seconds: 15) {
            try await provider.receiverPlaybackSession(for: book)
        }
        do {
            try Task.checkCancellation()
            let duration = session.audioTracks.totalDuration
            if serverProgress == nil, profileSession.serverSyncEnabled, let sessionTime = session.serverCurrentTime {
                serverProgress = CastProgressSample(position: sessionTime, updatedAt: .distantPast)
            }
            let requested = startPosition ?? CastResumePolicy.resumePosition(
                local: localProgressSamples(for: book), server: serverProgress,
                tolerance: AppConstants.Playback.resumeTimeTolerance)
            let resume = resolvePlaybackResumeTime(
                requestedTime: requested, sessionTime: nil, duration: duration,
                tolerance: AppConstants.Playback.resumeTimeTolerance)
            let plan = try CastMediaPlan(tracks: session.audioTracks, resumeAt: resume, streamingHeaders: provider.getStreamingHeaders())
            var timelineBook = book.withPlaybackSessionTimeline(
                tracks: session.audioTracks, duration: duration > 0 ? duration : book.duration)
            if (timelineBook.chapters?.isEmpty ?? true), !session.chapters.isEmpty {
                timelineBook.chapters = session.chapters
            }
            return LoadedMedia(book: timelineBook, provider: provider, sessionId: session.sessionId, plan: plan)
        } catch {
            let sessionId = session.sessionId
            let position = startPosition ?? book.currentTime
            enqueue(book.stableId) { await provider.reportPlayback(.stopped, book: book, sessionId: sessionId, position: position) }
            throw error
        }
    }

    private func localProgressSamples(for book: Book) -> [CastProgressSample] {
        var samples: [CastProgressSample] = []
        if let progress = profileSession.progress.progress(for: book) {
            samples.append(CastProgressSample(position: progress.currentTime, updatedAt: progress.lastUpdate))
        }
        if let stored = profileSession.bookProgress.loadProgress(for: book) {
            samples.append(CastProgressSample(position: stored.progress, updatedAt: Date(timeIntervalSince1970: stored.lastUpdated)))
        }
        if book.currentTime > 0 {
            samples.append(CastProgressSample(position: book.currentTime, updatedAt: book.lastUpdate))
        }
        return samples
    }

    private func send(_ media: LoadedMedia, intent: Intent, localResume: Bool, generation: Int) throws {
        guard let client = currentSession?.remoteMediaClient else { throw CastPlaybackError.notConnected }
        let items = media.plan.entries.map { entry in
            let info = GCKMediaInformationBuilder(contentURL: entry.url)
            info.streamType = .buffered
            info.contentType = entry.mimeType
            if entry.duration > 0 { info.streamDuration = entry.duration }
            info.metadata = metadata(for: media.book, entry: entry, count: media.plan.entries.count)
            let item = GCKMediaQueueItemBuilder()
            item.mediaInformation = info.build()
            item.autoplay = true
            item.preloadTime = 20
            return item.build()
        }
        let queue = GCKMediaQueueDataBuilder(queueType: .audioBook)
        queue.name = media.book.title
        queue.items = items
        queue.startIndex = UInt(media.plan.startIndex)
        queue.startTime = media.plan.startTime
        let request = GCKMediaLoadRequestDataBuilder()
        request.queueData = queue.build()
        request.autoplay = NSNumber(value: intent.autoplay)
        let rememberedRate = media.book.isPodcastEpisode ? nil : profileSession.playbackSpeed.speed(forStableId: media.book.stableId)
        request.playbackRate = Float(clampedRate(intent.rateOverride ?? rememberedRate ?? Double(localPlayback.playbackSpeed)))

        let sent = client.loadMedia(with: request.build())
        sent.delegate = self
        pending = PendingLoad(
            generation: generation, media: media, requestedAutoplay: intent.autoplay,
            intent: intent, localResume: localResume, request: sent
        )
        notifyChange()
    }

    private func metadata(for book: Book, entry: CastQueueEntry, count: Int) -> GCKMediaMetadata {
        let metadata = GCKMediaMetadata(metadataType: .audioBookChapter)
        metadata.setString(book.title, forKey: kGCKMetadataKeyBookTitle)
        metadata.setString(count > 1 ? (entry.title ?? "Part \(entry.trackIndex + 1)") : book.title, forKey: kGCKMetadataKeyTitle)
        if let author = book.author, !author.isEmpty { metadata.setString(author, forKey: kGCKMetadataKeySubtitle) }
        if let cover = book.coverURL?.absoluteString,
            let url = try? CastCompatibility.receiverURL(for: cover, streamingHeaders: [:])
        {
            metadata.addImage(GCKImage(url: url, width: 600, height: 600))
        }
        return metadata
    }

    private func completePending(_ request: GCKRequest) {
        guard let loaded = pending, loaded.request === request else { return }
        pending = nil
        loadTask?.cancel()
        endedSnapshot = nil
        if let previous = active {
            finalize(previous)
        }
        let plan = loaded.media.plan
        active = ActiveCast(
            media: loaded.media,
            position: plan.startPosition,
            isPlaying: loaded.intent.autoplay,
            trackIndex: plan.startIndex
        )
        // Local playback is surrendered only once the receiver has accepted the queue.
        if localPlayback.currentBook != nil { localPlayback.stop() }
        NowPlayingCoordinator.shared.setActive(self)
        profileSession.appState.currentBook = loaded.media.book
        // Transport commands issued while loading were held; the receiver still has the original autoplay.
        if loaded.intent.autoplay != loaded.requestedAutoplay {
            if loaded.intent.autoplay { observedClient?.play() } else { observedClient?.pause() }
        }
        if let override = loaded.intent.seekOverride { seek(to: override) }
        if let rate = loaded.intent.rateOverride { observedClient?.setPlaybackRate(Float(rate)) }
        startTicking()
        notifyChange()
    }

    private func failPending(_ error: CastPlaybackError, stopReceiver: Bool) {
        guard let failed = pending else { return }
        neutralize(failed, stopReceiver: stopReceiver || failed.localResume)
        if failed.localResume, localPlayback.currentBook != nil { localPlayback.play() }
        reportFailure(error, title: failed.media.book.title)
        notifyChange()
    }

    private func abandonPending(stopReceiver: Bool) {
        guard let abandoned = pending else { return }
        neutralize(abandoned, stopReceiver: stopReceiver)
    }

    private func neutralize(_ load: PendingLoad, stopReceiver: Bool) {
        pending = nil
        loadTask?.cancel()
        load.request.delegate = nil
        load.request.cancel()
        // A load that reached the receiver after we gave up would otherwise play unowned.
        if stopReceiver { observedClient?.stop() }
        closeServerSession(of: load.media, position: load.media.plan.startPosition)
    }

    private func isCurrent(_ generation: Int) -> Bool {
        !Task.isCancelled && !isRetired && generation == self.generation && isConnected
    }

    func play() {
        if preparing != nil { preparing?.intent.autoplay = true; notifyChange(); return }
        if pending != nil { pending?.intent.autoplay = true; notifyChange(); return }
        guard active != nil, let client = observedClient else { return }
        client.play()
    }

    func pause() {
        if preparing != nil { preparing?.intent.autoplay = false; notifyChange(); return }
        if pending != nil { pending?.intent.autoplay = false; notifyChange(); return }
        guard active != nil, let client = observedClient else { return }
        client.pause()
    }

    func togglePlay() {
        if let intent = preparing?.intent ?? pending?.intent {
            intent.autoplay ? pause() : play()
            return
        }
        (active?.isPlaying ?? false) ? pause() : play()
    }

    func stop() {
        generation &+= 1
        loadTask?.cancel()
        let hadPending = pending != nil
        if let stale = preparing {
            preparing = nil
            if stale.localResume, localPlayback.currentBook != nil { localPlayback.play() }
        }
        abandonPending(stopReceiver: true)
        if let current = active {
            active = nil
            finalize(current)
            if !hadPending { observedClient?.stop() }
        }
        endedSnapshot = nil
        stopTicking()
        notifyChange()
    }

    func seek(to globalTime: TimeInterval) {
        let target = max(0, globalTime)
        if preparing != nil { preparing?.intent.seekOverride = target; notifyChange(); return }
        if pending != nil { pending?.intent.seekOverride = target; notifyChange(); return }
        guard var current = active, let client = observedClient else { return }
        let destination = current.media.plan.target(forGlobalPosition: target)
        if destination.trackIndex == current.trackIndex {
            let options = GCKMediaSeekOptions()
            options.interval = destination.localPosition
            client.seek(with: options)
        } else if let item = client.mediaStatus?.queueItem(at: UInt(destination.trackIndex)) {
            client.queueJumpToItem(withID: item.itemID, playPosition: destination.localPosition, customData: nil)
        } else {
            return
        }
        current.trackIndex = destination.trackIndex
        current.position = current.media.plan.globalPosition(trackIndex: destination.trackIndex, localPosition: destination.localPosition)
        active = current
        persistActive(force: true)
        notifyChange()
    }

    func skip(by seconds: TimeInterval) {
        guard let position = livePosition ?? snapshot?.position else { return }
        seek(to: max(0, position + seconds))
    }

    func setPlaybackRate(_ rate: Double) {
        guard let book = preparing?.book ?? pending?.media.book ?? active?.media.book else { return }
        let clamped = clampedRate(rate)
        if !book.isPodcastEpisode { profileSession.playbackSpeed.remember(clamped, forStableId: book.stableId) }
        if preparing != nil {
            preparing?.intent.rateOverride = clamped
        } else if pending != nil {
            pending?.intent.rateOverride = clamped
        } else if active != nil {
            observedClient?.setPlaybackRate(Float(clamped))
        }
        notifyChange()
    }

    func setVolume(_ volume: Double) {
        currentSession?.setDeviceVolume(Float(min(max(volume, 0), 1)))
    }

    func updateChapters(_ chapters: [Chapter], for book: Book) {
        guard var current = active, current.media.book.stableId == book.stableId else { return }
        current.media.book.chapters = chapters
        active = current
        notifyChange()
    }

    func resumeEndedPlaybackLocally() -> Bool {
        guard let ended = endedSnapshot, let book = ended.currentBook, let resumeLocally else { return false }
        endedSnapshot = nil
        resumeLocally(book, ended.position >= ended.duration - 1 && ended.duration > 0 ? 0 : ended.position)
        return true
    }

    private func clampedRate(_ rate: Double) -> Double {
        min(max(rate, Self.receiverRateRange.lowerBound), Self.receiverRateRange.upperBound)
    }

    private func duration(of media: LoadedMedia) -> TimeInterval {
        let planned = media.plan.duration
        return planned > 0 ? planned : media.book.duration ?? 0
    }

    private func adopt(_ session: GCKCastSession) {
        connection = .connected(deviceName: session.device.friendlyName ?? "Cast device")
        if observedClient !== session.remoteMediaClient {
            observedClient?.remove(self)
            observedClient = session.remoteMediaClient
            observedClient?.add(self)
        }
        notifyChange()
    }

    // A session the SDK restores on its own was never chosen in this run, so it must not capture playback.
    private func releaseRestoredSession() {
        sessionManager?.endSessionAndStopCasting(false)
        connection = .disconnected
        notifyChange()
    }

    private func apply(_ status: GCKMediaStatus?) {
        guard var current = active, let status else { return }
        let plan = current.media.plan
        if status.playerState == .idle {
            switch status.idleReason {
            case .finished where status.mediaInformation == nil || current.trackIndex == plan.entries.count - 1:
                current.position = duration(of: current.media)
                current.isPlaying = false
                active = nil
                finalize(current)
                stopTicking()
                endedSnapshot = endedState(for: current, position: current.position)
                onEvent?(.completed(current.media.book))
                notifyChange()
            case .error, .interrupted, .cancelled:
                active = nil
                finalize(current)
                stopTicking()
                if pending == nil, preparing == nil {
                    if status.idleReason == .error { reportFailure(.loadFailed, title: current.media.book.title) }
                    endedSnapshot = endedState(for: current, position: current.position)
                }
                notifyChange()
            default:
                break
            }
            return
        }
        if let url = status.mediaInformation?.contentURL {
            guard let index = plan.entries.firstIndex(where: { $0.url == url }) else {
                // Another load replaced ours, either our next book or a different sender.
                active = nil
                finalize(current)
                stopTicking()
                if pending == nil, preparing == nil { endedSnapshot = endedState(for: current, position: current.position) }
                notifyChange()
                return
            }
            current.trackIndex = index
        }
        let wasPlaying = current.isPlaying
        current.isPlaying = status.playerState == .playing || status.playerState == .buffering || status.playerState == .loading
        current.isBuffering = status.playerState == .buffering || status.playerState == .loading
        current.position = plan.globalPosition(trackIndex: current.trackIndex, localPosition: status.streamPosition)
        active = current
        if current.isPlaying != wasPlaying || !current.reportedStart {
            playStateChanged(current, wasPlaying: wasPlaying)
        }
        notifyChange()
    }

    private func playStateChanged(_ current: ActiveCast, wasPlaying: Bool) {
        let book = current.media.book
        let position = current.position
        let duration = duration(of: current.media)
        if current.isPlaying {
            let event: ServerPlaybackEvent = current.reportedStart ? .resumed : .started
            active?.reportedStart = true
            reportPlayback(event, media: current.media, position: position)
            let rate = playbackRate
            enqueue(book.stableId) { [profileSession] in
                await profileSession.listeningStats.startSession(bookId: book.stableId, position: position, playbackRate: rate, duration: duration)
            }
        } else if wasPlaying {
            reportPlayback(.paused, media: current.media, position: position)
            persistActive(force: true)
            enqueue(book.stableId) { [profileSession] in
                await profileSession.listeningStats.endSession(bookId: book.stableId, finalPosition: position, duration: duration)
            }
        }
    }

    private func endedState(for current: ActiveCast, position: TimeInterval) -> PlaybackSnapshot {
        PlaybackSnapshot(
            currentBook: current.media.book, isPlaying: false, position: position,
            duration: duration(of: current.media), playbackSpeed: playbackRate, volume: 1,
            isLoaded: false, isLoading: false, isOverlayPlaybackActive: false, errorDescription: nil
        )
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() {
        guard var current = active, let position = livePosition else { return }
        let now = Date()
        if current.isPlaying, !current.isBuffering {
            current.listenedSinceSync += min(now.timeIntervalSince(current.lastTickAt), 5)
        }
        current.lastTickAt = now
        current.position = position
        current.media.book.currentTime = position
        active = current
        if current.isPlaying { persistActive(force: false) }
        notifyChange()
    }

    private func persistActive(force: Bool) {
        guard var current = active else { return }
        let now = Date()
        let saveLocal = force || now.timeIntervalSince(current.lastLocalSaveAt) >= 20
        let pushServer = force || (current.isPlaying && now.timeIntervalSince(current.lastServerPushAt) >= 30)
        guard saveLocal || pushServer else { return }
        if saveLocal { current.lastLocalSaveAt = now }
        let listened = pushServer ? current.listenedSinceSync : 0
        if pushServer {
            current.lastServerPushAt = now
            current.listenedSinceSync = 0
        }
        active = current
        persist(current.media, position: current.position, listened: listened, force: force, pushServer: pushServer)
    }

    private func finalize(_ current: ActiveCast) {
        let book = current.media.book
        let position = current.position
        let duration = duration(of: current.media)
        persist(current.media, position: position, listened: current.listenedSinceSync, force: true, pushServer: true)
        closeServerSession(of: current.media, position: position)
        enqueue(book.stableId) { [profileSession] in
            await profileSession.listeningStats.endSession(bookId: book.stableId, finalPosition: position, duration: duration)
        }
    }

    private func persist(_ media: LoadedMedia, position: TimeInterval, listened: TimeInterval, force: Bool, pushServer: Bool) {
        let book = media.book
        let duration = duration(of: media)
        let finished = duration > 0 && position >= duration - 5
        let now = Date()
        profileSession.progress.update(
            UserMediaProgress(
                id: UUID().uuidString,
                libraryItemId: book.isPodcastEpisode ? (book.podcastLibraryItemId ?? book.id) : book.id,
                providerId: book.providerId,
                episodeId: book.episodeId,
                currentTime: position,
                progress: duration > 0 ? position / duration : 0,
                isFinished: finished,
                duration: duration,
                lastUpdate: now,
                ebookProgress: nil
            )
        )
        profileSession.bookProgress.saveProgress(for: book, progress: position, duration: duration, at: now)

        let session = profileSession
        let resolution = session.pendingSync.downloadedProgressResolution(for: book.stableId)
        enqueue(book.stableId) {
            await session.playback.linkedProgress.recordAudiobookProgress(
                book: book, currentTime: position, isFinished: finished, observedAt: now, authoritative: force)
            await session.playback.workProgress.fanOut(
                from: book, fraction: duration > 0 ? position / duration : 0, isFinished: finished, force: force)
            guard pushServer, media.provider is any AudiobookProgressPushing,
                session.serverSyncEnabled, session.progress.syncProgressToServer,
                session.pendingSync.downloadedProgressResolution(for: book.stableId) == resolution
            else { return }
            await session.sync.pushAudiobookProgress(
                book: book, position: position, sessionId: media.sessionId,
                isFinished: finished, timeListened: listened, forceImmediate: true)
        }
    }

    private func reportPlayback(_ event: ServerPlaybackEvent, media: LoadedMedia, position: TimeInterval) {
        guard let provider = media.provider, let sessionId = media.sessionId else { return }
        let book = media.book
        let session = profileSession
        guard session.serverSyncEnabled, session.progress.syncProgressToServer,
            session.pendingSync.entries[book.stableId]?.downloadedBaseline == nil
        else { return }
        enqueue(book.stableId) { await provider.reportPlayback(event, book: book, sessionId: sessionId, position: position) }
    }

    private func closeServerSession(of media: LoadedMedia, position: TimeInterval) {
        guard let provider = media.provider, let sessionId = media.sessionId, profileSession.serverSyncEnabled else { return }
        let book = media.book
        enqueue(book.stableId) { await provider.reportPlayback(.stopped, book: book, sessionId: sessionId, position: position) }
    }

    private func reportFailure(_ error: CastPlaybackError, title: String) {
        guard !isRetired else { return }
        profileSession.appState.presentation.userFacingError = UserFacingError(
            title: "Couldn't Cast \"\(title)\"",
            message: error.errorDescription ?? ""
        )
    }

    /// Progress, stats and server-session work for one book run in submission order, like the local player's sync path.
    private func enqueue(_ bookId: String, _ operation: @escaping @MainActor () async -> Void) {
        guard acceptsOperations else { return }
        let id = UUID()
        let queue = progressQueue
        operations[id] = Task { [weak self] in
            await queue.enqueue(bookId: bookId, operation: operation)
            self?.operations.removeValue(forKey: id)
        }
    }

    private func notifyChange() {
        refreshNowPlayingInfo()
        onStateChange?()
    }

    func refreshNowPlayingInfo() {
        guard NowPlayingCoordinator.shared.isActive(self),
            let state = snapshot ?? endedSnapshot, let book = state.currentBook
        else { return }
        let metadata = resolveAudiobookNowPlayingMetadata(
            book: book, currentTime: state.position, playbackDuration: state.duration)
        NowPlayingCoordinator.shared.updateNowPlaying(NowPlayingInfo(
            title: book.title,
            artist: metadata.chapterTitle ?? book.author,
            albumTitle: book.author,
            duration: metadata.duration,
            elapsed: metadata.elapsed,
            showsProgress: profileSession.preferences.loadPreferences().showLockScreenProgressBar,
            rate: state.isPlaying ? state.playbackSpeed : 0,
            defaultRate: state.playbackSpeed,
            mediaType: .audio,
            contentIdentifier: book.stableId,
            collectionIdentifier: book.providerId.uuidString,
            serviceIdentifier: Bundle.main.bundleIdentifier,
            chapterNumber: metadata.chapterNumber,
            chapterCount: metadata.chapterCount,
            artworkURL: book.coverURL
        ))
    }

    private func sessionEnded(error: Error?) {
        generation &+= 1
        loadTask?.cancel()
        // A handoff that never reached the receiver rolls back to the local player it paused.
        let rollBackLocal = preparing?.localResume == true || pending?.localResume == true
        preparing = nil
        abandonPending(stopReceiver: false)
        if rollBackLocal, localPlayback.currentBook != nil { localPlayback.play() }
        if let current = active {
            active = nil
            finalize(current)
            endedSnapshot = endedState(for: current, position: current.position)
        }
        stopTicking()
        observedClient?.remove(self)
        observedClient = nil
        hasUserIntent = false
        connection = .disconnected
        if error != nil, let title = endedSnapshot?.currentBook?.title {
            reportFailure(.notConnected, title: title)
        }
        notifyChange()
    }

    func retire() async {
        guard !isRetired else { return }
        isRetired = true
        generation &+= 1
        let ownsReceiver = active != nil || pending != nil
        sessionManager?.remove(self)
        observedClient?.remove(self)
        let preparation = loadTask
        preparation?.cancel()
        preparing = nil
        abandonPending(stopReceiver: false)
        // A provider session opened by a cancelled preparation is closed by that task before it finishes.
        await preparation?.value
        if let current = active {
            active = nil
            finalize(current)
        }
        stopTicking()
        // Ending the device session keeps the next profile from inheriting this profile's receiver queue.
        if ownsReceiver, sessionManager?.hasConnectedCastSession() == true { sessionManager?.endSessionAndStopCasting(true) }
        observedClient = nil
        sessionManager = nil
        endedSnapshot = nil
        hasUserIntent = false
        NowPlayingCoordinator.shared.clearNowPlaying(if: self)
        NowPlayingCoordinator.shared.resignIfActive(self)
        onStateChange = nil
        onEvent = nil
        resumeLocally = nil
        for task in Array(operations.values) { await task.value }
        acceptsOperations = false
        operations.removeAll()
        await progressQueue.retire()
    }
}

extension CastPlaybackService: RemoteCommandTarget {
    func remotePlay() {
        if !ownsPlayback, resumeEndedPlaybackLocally() { return }
        play()
    }
    func remotePause() { pause() }
    func remoteToggle() { snapshot?.isPlaying == true ? pause() : remotePlay() }
    func remoteNext() { skip(by: remoteSkipForwardInterval) }
    func remotePrevious() { skip(by: -remoteSkipBackwardInterval) }
    func remoteSkipForward(by seconds: TimeInterval?) { skip(by: seconds ?? remoteSkipForwardInterval) }
    func remoteSkipBackward(by seconds: TimeInterval?) { skip(by: -(seconds ?? remoteSkipBackwardInterval)) }
    func remoteSeek(to positionTime: TimeInterval) { seek(to: positionTime) }
    var remoteSkipForwardInterval: TimeInterval { localPlayback.skipForwardInterval }
    var remoteSkipBackwardInterval: TimeInterval { localPlayback.skipBackwardInterval }
}

extension CastPlaybackService: @preconcurrency GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, willStart session: GCKSession) {
        guard !isRetired else { return }
        connection = .connecting
        notifyChange()
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        guard !isRetired, let session = session as? GCKCastSession else { return }
        hasUserIntent = true
        adopt(session)
        handOffLocalPlayback()
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        guard !isRetired, let session = session as? GCKCastSession else { return }
        guard hasUserIntent else {
            releaseRestoredSession()
            return
        }
        adopt(session)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        guard !isRetired else { return }
        sessionEnded(error: error)
    }

    func sessionManager(_ sessionManager: GCKSessionManager, didFailToStart session: GCKSession, withError error: Error) {
        guard !isRetired else { return }
        hasUserIntent = false
        connection = .disconnected
        notifyChange()
    }

    func sessionManager(
        _ sessionManager: GCKSessionManager, didSuspend session: GCKSession, with reason: GCKConnectionSuspendReason
    ) {
        guard !isRetired else { return }
        // The SDK reconnects suspended sessions itself; the receiver keeps playing meanwhile.
        failPending(.notConnected, stopReceiver: false)
        persistActive(force: true)
        connection = .connecting
        notifyChange()
    }
}

extension CastPlaybackService: @preconcurrency GCKRemoteMediaClientListener {
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        guard !isRetired, client === observedClient else { return }
        apply(mediaStatus)
    }
}

extension CastPlaybackService: @preconcurrency GCKRequestDelegate {
    func requestDidComplete(_ request: GCKRequest) {
        guard !isRetired else { return }
        completePending(request)
    }

    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        guard !isRetired, pending?.request === request else { return }
        AppLogger.player.warning("Cast load failed code=\(error.code)")
        failPending(.loadFailed, stopReceiver: false)
    }

    func request(_ request: GCKRequest, didAbortWith abortReason: GCKRequestAbortReason) {
        guard !isRetired, pending?.request === request else { return }
        failPending(.loadFailed, stopReceiver: false)
    }
}
#endif
