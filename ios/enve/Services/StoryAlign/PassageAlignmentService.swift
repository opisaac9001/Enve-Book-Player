#if os(iOS)
import AVFoundation
#if !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif
import Foundation
import Logging
import StoryAlignCore
import UIKit

enum PassagePreparationReason: Int, Comparable, Sendable {
    case handoff
    case playback
    case wholeBook
    case lookAhead

    var isSpeculative: Bool { self == .playback || self == .lookAhead }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated struct PassageWindowRef: Hashable, Sendable {
    let trackIndex: Int
    let windowIndex: Int
}

struct PassagePairStatus: Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        case idle
        case identifying
        /// Media identity is established; the alignment engine and the book's text index are loading.
        case loadingEngine
        case preparing
        case paused(PassageUnavailableReason)
    }

    var activity: Activity = .idle
    var engine: PassageEngineKind?
    var coveredSeconds: TimeInterval = 0
    var totalSeconds: TimeInterval = 0
    var analyzing: PassageWindowRef?
    /// Windows whose analysis threw in this session; only an explicit retry queues them again.
    var failedWindows: Set<PassageWindowRef> = []
    /// The explicit retry that is opening its session and has not queued its windows yet.
    var retryRequest: UUID?

    var isRetrying: Bool { retryRequest != nil }
}

/// Profile-owned orchestration of incremental passage preparation. One analysis session (one pair, one engine)
/// is active at a time; window jobs run off the main actor and commit through `PassageAlignmentStore`.
@MainActor
@Observable
final class PassageAlignmentService {
    static let lookAhead: TimeInterval = 120
    static let lookBehind: TimeInterval = 30
    static let handoffBudget: Duration = .seconds(30)

    let store: PassageAlignmentStore
    private(set) var statuses: [String: PassagePairStatus] = [:]

    /// Off pauses running and queued preparation without discarding it; on resumes it under the resource policy.
    var generationEnabled: Bool {
        didSet {
            guard generationEnabled != oldValue else { return }
            defaults.set(generationEnabled, forKey: Self.generationKey)
            if generationEnabled { resumeQueuedWork() } else { pauseWork(.generationDisabled) }
        }
    }
    /// Off withholds saved passages from every consumer, including resolutions already in flight; nothing is deleted.
    var cachedMappingsEnabled: Bool {
        didSet {
            guard cachedMappingsEnabled != oldValue else { return }
            defaults.set(cachedMappingsEnabled, forKey: Self.cachedKey)
            mappingsEpoch += 1
            store.noteExternalChange()
        }
    }

    /// The engine Listen Along prepares with; nil is automatic, which prefers Apple Speech where the system has it.
    /// Independent of StoryAlign's full-book conversion method. A change ends the session; passages are kept.
    var liveEngine: PassageEngineKind? {
        didSet {
            guard liveEngine != oldValue else { return }
            defaults.set(liveEngine?.rawValue, forKey: Self.liveEngineKey)
            if session != nil || opening != nil { startClosing() }
        }
    }

    /// The engine `capability` picks for a book in this language, before media and resource checks.
    func selectedEngine(language: String?) -> Result<PassageEngineKind, PassageUnavailableReason> {
        Self.selectEngine(
            preferred: liveEngine, language: language, quartzNetSupported: QuartzNetModelPackage.isSupported,
            modelInstalled: modelDirectoryProvider() != nil, appleSpeechSystem: Self.appleSpeechSystemAvailable
        )
    }

    @ObservationIgnored private unowned let profileSession: ProfileSession
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let identities: PassageMediaIdentityResolver
    @ObservationIgnored private let workingDirectory: URL
    @ObservationIgnored private var session: PreparationSession?
    @ObservationIgnored private var opening: Opening?
    @ObservationIgnored private var closing: (token: UUID, task: Task<Bool?, Never>)?
    @ObservationIgnored private var queue: [WindowJob] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var identityTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var generation = 0
    /// Bumped when saved passages are switched off or removed, so a resolution that started earlier returns nothing.
    @ObservationIgnored private(set) var mappingsEpoch = 0
    /// While set, removal is underway: no preparation starts and no saved passage is returned.
    @ObservationIgnored private var clearing: Task<Void, Never>?
    @ObservationIgnored private var pendingHandoffWaits: [Int: [UUID: () -> Void]] = [:]
    @ObservationIgnored private var isStorageBlocked = false
    @ObservationIgnored private var openRequests: Set<UUID> = []
    @ObservationIgnored private var withdrawnRequests: Set<UUID> = []
    @ObservationIgnored private var storageRetry: Task<Void, Never>?
    @ObservationIgnored private var isRetired = false
    @ObservationIgnored private(set) var isInBackground = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored var modelDirectoryProvider: () -> URL? = { StoryAlignModelStore.shared.installedModelDirectory }
    /// Replaces engine and identity startup; tests use it to control when a session becomes ready.
    @ObservationIgnored var sessionBuilderOverride: (@MainActor (SessionRequest) async throws -> PreparationSession)?
    @ObservationIgnored var mappingLoadOverride: (@MainActor (PassageMediaIdentity) async -> PassageMappingSet?)?
    @ObservationIgnored var acousticLimit = PassageAlignmentStore.acousticLimitBytes
    @ObservationIgnored var storageRetryDelay: Duration = .seconds(60)
    /// Preparation pauses below this much free space, before saving fails for the rest of the app too.
    @ObservationIgnored var minimumFreeBytes: Int64 = 256 * 1_024 * 1_024

    private static let generationKey = "passageAlignment.generationEnabled"
    private static let cachedKey = "passageAlignment.cachedMappingsEnabled"
    private static let liveEngineKey = "passageAlignment.liveEngine"

    private struct WindowJob {
        let trackIndex: Int
        let window: CTCPassageWindow
        let reason: PassagePreparationReason
        let generation: Int
        var request: UUID?
    }

    /// One in-flight session startup. Only the opening that still holds the current token may install its session.
    private struct Opening {
        let key: String
        let token: UUID
        let task: Task<PreparationSession?, Never>
    }

    struct SessionRequest {
        let key: String
        let ebook: Book
        let audiobook: Book
        let kind: PassageEngineKind
        let media: PassageMedia
    }

    final class PreparationSession {
        let key: String
        let ebook: Book
        let audiobook: Book
        let identity: PassageMediaIdentity
        let tracks: [PassageTrack]
        let engine: any PassageAlignmentEngine
        let kind: PassageEngineKind
        let sentences: [PassageSentence]
        let readyAt = ContinuousClock.now
        var analyzedWindows = 0
        var buffer = PassageBufferPolicy()

        init(key: String, ebook: Book, audiobook: Book, identity: PassageMediaIdentity, tracks: [PassageTrack], engine: any PassageAlignmentEngine, kind: PassageEngineKind, sentences: [PassageSentence]) {
            self.key = key
            self.ebook = ebook
            self.audiobook = audiobook
            self.identity = identity
            self.tracks = tracks
            self.engine = engine
            self.kind = kind
            self.sentences = sentences
        }

        func grid(_ trackIndex: Int) -> [CTCPassageWindow] {
            CTCPassageWindow.grid(trackDuration: tracks[trackIndex].duration)
        }
    }

    init(profileSession: ProfileSession, root: URL? = nil) {
        self.profileSession = profileSession
        defaults = profileSession.defaults
        let base = root ?? profileSession.storage.applicationSupportDirectory.appendingPathComponent("Enve/PassageAlignment", isDirectory: true)
        store = PassageAlignmentStore(root: base)
        identities = PassageMediaIdentityResolver(cacheURL: base.appendingPathComponent("media-identity.json"))
        workingDirectory = profileSession.storage.cachesDirectory.appendingPathComponent("PassageAlignment", isDirectory: true)
        generationEnabled = profileSession.defaults.object(forKey: Self.generationKey) as? Bool ?? true
        cachedMappingsEnabled = profileSession.defaults.object(forKey: Self.cachedKey) as? Bool ?? true
        liveEngine = profileSession.defaults.string(forKey: Self.liveEngineKey).flatMap(PassageEngineKind.init(rawValue:))
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.environmentDidChange() }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.environmentDidChange() }
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.session?.engine.release() }
        })
    }

    static func pairKey(ebook: Book, audiobook: Book) -> String {
        PassageAlignmentStore.pairKey(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId)
    }

    func status(ebook: Book, audiobook: Book) -> PassagePairStatus {
        statuses[Self.pairKey(ebook: ebook, audiobook: audiobook)] ?? PassagePairStatus()
    }

    var activeSessionKey: String? { session?.key }
    var queuedWindows: [(trackIndex: Int, windowIndex: Int, reason: PassagePreparationReason)] {
        queue.map { ($0.trackIndex, $0.window.index, $0.reason) }
    }
    var isWorking: Bool { worker != nil }

    /// Whether a window of the pair's installed session is queued or being analyzed.
    func isPending(_ window: PassageWindowRef, ebook: Book, audiobook: Book) -> Bool {
        let key = Self.pairKey(ebook: ebook, audiobook: audiobook)
        guard session?.key == key else { return false }
        return statuses[key]?.analyzing == window
            || queue.contains { $0.trackIndex == window.trackIndex && $0.window.index == window.windowIndex }
    }

    /// The prepared position for a time on the complete audiobook timeline. Never hashes media or starts analysis;
    /// unverified identity withholds cached mappings and schedules verification off the playback path.
    func audioResolution(ebook: Book, audiobook: Book, bookTime: TimeInterval) async -> PassageAudioResolution {
        let epoch = mappingsEpoch
        guard let context = await verifiedContext(ebook: ebook, audiobook: audiobook),
            let set = await store.mappingSet(for: context.identity),
            mappingsReadable(since: epoch),
            let local = Self.localPosition(bookTime: bookTime, layout: context.layout)
        else { return .unprepared }
        return set.resolve(trackIndex: local.track, time: local.time)
    }

    func textResolution(ebook: Book, audiobook: Book, href: String, quote: String, chapterProgression: Double?) async -> PassageTextResolution {
        let epoch = mappingsEpoch
        guard let context = await verifiedContext(ebook: ebook, audiobook: audiobook) else { return .unprepared(nil) }
        let set = await store.mappingSet(for: context.identity) ?? PassageMappingSet(identity: context.identity)
        // Without the full sentence index only mapped sentences can be identified; unspoken text then stays unprepared.
        let sentences = await store.textIndex(for: context.identity) ?? set.mappings.map {
            PassageSentence(key: $0.key, href: $0.href, text: $0.text, chapterProgression: $0.chapterProgression, totalProgression: $0.totalProgression)
        }
        guard mappingsReadable(since: epoch) else { return .unprepared(nil) }
        return set.resolve(href: href, quote: quote, chapterProgression: chapterProgression, sentences: sentences)
    }

    /// Converts a mapping's track-local time to the player's complete timeline.
    func bookTime(of mapping: PassageMapping, audiobook: Book) -> TimeInterval? {
        guard let layout = profileSession.playback.manager.readAlongPlaybackLayout(for: audiobook)?.tracks,
            layout.indices.contains(mapping.trackIndex)
        else { return nil }
        return layout[mapping.trackIndex].startOffset + mapping.start
    }

    func originalEPUBURL(ebook: Book, audiobook: Book) -> URL? {
        playbackMedia(ebook: ebook, audiobook: audiobook)?.epub
    }

    /// Whether the file the reader opened is the original EPUB revision passages are prepared from.
    /// An accepted narrated EPUB or a converted file is a different reading revision.
    func isPreparedReadingRevision(ebook: Book, audiobook: Book, openedFileURL: URL) async -> Bool {
        guard cachedMappingsEnabled, let media = playbackMedia(ebook: ebook, audiobook: audiobook) else { return false }
        if media.epub.standardizedFileURL.resolvingSymlinksInPath() == openedFileURL.standardizedFileURL.resolvingSymlinksInPath() {
            return true
        }
        guard let opened = try? await identities.digest(of: openedFileURL) else { return false }
        return (try? await identities.digest(of: media.epub)) == opened
    }

    /// Mapping and player layout for per-tick read-along resolution without file checks on every tick.
    struct ReadAlongContext {
        let set: PassageMappingSet
        let layout: [AudioTrackInfo]

        func resolve(bookTime: TimeInterval) -> PassageAudioResolution {
            guard let local = PassageAlignmentService.localPosition(bookTime: bookTime, layout: layout) else { return .unprepared }
            return set.resolve(trackIndex: local.track, time: local.time)
        }

        func bookTime(of mapping: PassageMapping) -> TimeInterval? {
            layout.indices.contains(mapping.trackIndex) ? layout[mapping.trackIndex].startOffset + mapping.start : nil
        }

        /// The analysis window that owns the sentence ending at this position.
        func window(at bookTime: TimeInterval) -> PassageWindowRef? {
            guard let local = PassageAlignmentService.localPosition(bookTime: bookTime, layout: layout),
                let owner = CTCPassageWindow.owner(ofEnd: local.time, in: CTCPassageWindow.grid(trackDuration: layout[local.track].duration))
            else { return nil }
            return PassageWindowRef(trackIndex: local.track, windowIndex: owner.index)
        }

        /// Analyzed without enough confident sentences, and not accepted by any engine since.
        func wasRejected(_ window: PassageWindowRef) -> Bool {
            let records = set.windows.filter { $0.trackIndex == window.trackIndex && $0.windowIndex == window.windowIndex }
            return !records.isEmpty && !records.contains(where: \.accepted)
        }
    }

    func readAlongContext(ebook: Book, audiobook: Book) async -> ReadAlongContext? {
        let epoch = mappingsEpoch
        guard let context = await verifiedContext(ebook: ebook, audiobook: audiobook) else { return nil }
        let set = await store.mappingSet(for: context.identity) ?? PassageMappingSet(identity: context.identity)
        return mappingsReadable(since: epoch) ? ReadAlongContext(set: set, layout: context.layout) : nil
    }

    /// Validated mappings sampled across the book as Quick Sync anchors, so calibration reuses prepared work.
    func calibrationAnchors(ebook: Book, audiobook: Book, at fractions: [Double]) async -> [LinkedBookCalibrationAnchor] {
        let epoch = mappingsEpoch
        guard let context = await verifiedContext(ebook: ebook, audiobook: audiobook),
            let set = await store.mappingSet(for: context.identity),
            mappingsReadable(since: epoch)
        else { return [] }
        let total = context.layout.reduce(0) { $0 + $1.duration }
        guard total > 0 else { return [] }
        return fractions.compactMap { fraction in
            guard let local = Self.localPosition(bookTime: fraction * total, layout: context.layout),
                let mapping = set.resolve(trackIndex: local.track, time: local.time).handoffMapping
            else { return nil }
            let audioTime = context.layout[mapping.trackIndex].startOffset + mapping.start
            return LinkedBookCalibrationAnchor(
                ebookProgress: mapping.totalProgression, audioProgress: min(max(audioTime / total, 0), 1),
                quote: mapping.text, href: mapping.href, confidence: 0.95
            )
        }
    }

    private func mappingsReadable(since epoch: Int) -> Bool {
        cachedMappingsEnabled && !isRetired && clearing == nil && epoch == mappingsEpoch
    }

    private struct VerifiedContext {
        let identity: PassageMediaIdentity
        let layout: [AudioTrackInfo]
        let epubURL: URL
    }

    private func verifiedContext(ebook: Book, audiobook: Book) async -> VerifiedContext? {
        guard cachedMappingsEnabled, !isRetired, let media = playbackMedia(ebook: ebook, audiobook: audiobook) else { return nil }
        guard let identity = await identities.cachedIdentity(
            ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId, epubURL: media.epub, audioURLs: media.audio, streamSession: media.streamSession
        ) else {
            // Hash only pairs that already have prepared data; ordinary listening never triggers a full-media scan.
            if store.hasStoredMapping(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId) {
                establishIdentity(ebook: ebook, audiobook: audiobook, media: media)
            }
            return nil
        }
        return VerifiedContext(identity: identity, layout: media.layout, epubURL: media.epub)
    }

    private func establishIdentity(ebook: Book, audiobook: Book, media: PassageMedia) {
        let key = Self.pairKey(ebook: ebook, audiobook: audiobook)
        guard identityTasks[key] == nil, !isRetired else { return }
        identityTasks[key] = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = try? await identities.identity(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId, epubURL: media.epub, audioURLs: media.audio, streamSession: media.streamSession)
            identityTasks[key] = nil
            if !isRetired { store.noteExternalChange() }
        }
    }

    nonisolated static func localPosition(bookTime: TimeInterval, layout: [AudioTrackInfo]) -> (track: Int, time: TimeInterval)? {
        guard !layout.isEmpty, bookTime.isFinite else { return nil }
        let clamped = max(0, bookTime)
        let index = layout.lastIndex { $0.startOffset <= clamped } ?? 0
        let local = clamped - layout[index].startOffset
        return (index, layout[index].duration > 0 ? min(local, layout[index].duration) : local)
    }

    func capability(ebook: Book, audiobook: Book) -> Result<PassageEngineKind, PassageUnavailableReason> {
        guard generationEnabled else { return .failure(.generationDisabled) }
        if let url = ebookURL(ebook), !Self.isEPUB(url) { return .failure(.unsupportedFormat) }
        guard playbackMedia(ebook: ebook, audiobook: audiobook) != nil else { return .failure(.missingMedia) }
        if let blocker = resourceBlocker(for: .handoff) { return .failure(blocker) }
        return selectedEngine(language: audiobook.language ?? ebook.language)
    }

    nonisolated static var appleSpeechSystemAvailable: Bool {
        #if targetEnvironment(simulator) || targetEnvironment(macCatalyst)
        false
        #else
        if #available(iOS 26.0, *) { true } else { false }
        #endif
    }

    /// Without an explicit choice Apple Speech is used where the system has it, so no model download is needed.
    /// An explicit QuartzNet choice is kept for English. A saved Apple Speech choice on an older system is never
    /// executed or overwritten; English books use QuartzNet instead and other languages report why not.
    static func selectEngine(preferred: PassageEngineKind?, language: String?, quartzNetSupported: Bool, modelInstalled: Bool, appleSpeechSystem: Bool) -> Result<PassageEngineKind, PassageUnavailableReason> {
        let english = StoryAlignMethod.quartzNet.supports(language: language)
        if preferred != .quartzNet, appleSpeechSystem { return .success(.appleSpeech) }
        if english, quartzNetSupported {
            return modelInstalled ? .success(.quartzNet) : .failure(.modelDownloadRequired)
        }
        if appleSpeechSystem { return .success(.appleSpeech) }
        if preferred == .appleSpeech { return .failure(.unsupportedSystem) }
        return .failure(english ? .unsupportedHardware : .unsupportedLanguage)
    }

    private func resourceBlocker(for reason: PassagePreparationReason) -> PassageUnavailableReason? {
        let info = ProcessInfo.processInfo
        if info.thermalState == .serious || info.thermalState == .critical { return .pausedForTemperature }
        if isInBackground, !continuedProcessingGranted { return .backgroundUnavailable }
        if info.isLowPowerModeEnabled, reason != .handoff { return .pausedForPower }
        if profileSession.isOwner, profileSession.storyAlignService.activeConversion?.isComplete == false,
            profileSession.storyAlignService.activeConversion?.error == nil {
            return .busy
        }
        if AudiobookTranscriptionService.shared.activeBookStableId != nil { return .busy }
        return nil
    }

    /// Queues analysis around a position. A handoff or seek starts a new request generation, which drops
    /// queued work from older generations; already completed windows are kept. Windows that failed or found
    /// no confident match are analyzed again only when `retrying`, which the user asks for explicitly.
    @discardableResult
    func prepare(ebook: Book, audiobook: Book, around bookTime: TimeInterval, reason: PassagePreparationReason, ahead: TimeInterval = PassageAlignmentService.lookAhead, behind: TimeInterval = PassageAlignmentService.lookBehind, retrying: Bool = false) -> UUID {
        let id = UUID()
        guard !isRetired, clearing == nil, generationEnabled else { return id }
        let key = Self.pairKey(ebook: ebook, audiobook: audiobook)
        if case .paused(let blocker) = statuses[key]?.activity, blocker.needsUserAction {
            guard reason != .lookAhead else { return id }
            statuses[key]?.activity = .idle
        }
        let retry = retrying ? UUID() : nil
        if let retry { statuses[key, default: PassagePairStatus()].retryRequest = retry }
        if reason != .lookAhead { advanceGeneration() }
        let request = generation
        openRequests.insert(id)
        Task { [weak self] in
            guard let self else { return }
            // An older retry finishing late must not clear a newer one's state.
            defer {
                if let retry, statuses[key]?.retryRequest == retry { statuses[key]?.retryRequest = nil }
                openRequests.remove(id)
                withdrawnRequests.remove(id)
            }
            guard request == generation,
                let session = await openSession(ebook: ebook, audiobook: audiobook),
                session.key == key, request == generation, !withdrawnRequests.contains(id)
            else { return }
            await enqueue(session: session, around: bookTime, reason: reason, ahead: ahead, behind: behind, generation: request, retrying: retrying, owner: id)
        }
        return id
    }

    /// Listening→reading handoff. The budget starts at entry; a superseded, cancelled or expired request returns
    /// `.unprepared`, never a match. The playhead is re-read on every check, so playback elapsed meanwhile counts.
    func findReadingPosition(ebook: Book, audiobook: Book, playhead: @escaping @MainActor () -> TimeInterval, budget: Duration = PassageAlignmentService.handoffBudget) async -> PassageAudioResolution {
        let deadline = ContinuousClock.now.advanced(by: budget)
        advanceGeneration()
        let request = generation
        defer { removeHandoffJobs(of: request) }
        let cached = await audioResolution(ebook: ebook, audiobook: audiobook, bookTime: playhead())
        guard owns(request, until: deadline) else { return .unprepared }
        if cached.handoffMapping != nil { return cached }
        guard case .success = capability(ebook: ebook, audiobook: audiobook),
            let session = await openSession(ebook: ebook, audiobook: audiobook, deadline: deadline, request: request),
            owns(request, until: deadline)
        else { return .unprepared }
        await enqueue(session: session, around: playhead(), reason: .handoff, ahead: 40, behind: 0, generation: request)
        while owns(request, until: deadline) {
            let resolution = await audioResolution(ebook: ebook, audiobook: audiobook, bookTime: playhead())
            guard owns(request, until: deadline) else { return .unprepared }
            if resolution.handoffMapping != nil { return resolution }
            if !hasHandoffJobs(of: request), worker == nil { return resolution }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return .unprepared
    }

    /// Reading→listening handoff, analyzing outward from the estimated audio region under the same ownership rules.
    func findListeningPosition(ebook: Book, audiobook: Book, href: String, quote: String, chapterProgression: Double?, estimatedBookTime: TimeInterval, budget: Duration = PassageAlignmentService.handoffBudget) async -> PassageTextResolution {
        let deadline = ContinuousClock.now.advanced(by: budget)
        advanceGeneration()
        let request = generation
        defer { removeHandoffJobs(of: request) }
        func resolve() async -> PassageTextResolution? {
            let resolution = await textResolution(ebook: ebook, audiobook: audiobook, href: href, quote: quote, chapterProgression: chapterProgression)
            return owns(request, until: deadline) ? resolution : nil
        }
        guard let cached = await resolve() else { return .unprepared(nil) }
        switch cached {
        case .matched, .notSpoken, .ambiguous: return cached
        case .unprepared: break
        }
        guard case .success = capability(ebook: ebook, audiobook: audiobook),
            let session = await openSession(ebook: ebook, audiobook: audiobook, deadline: deadline, request: request),
            owns(request, until: deadline)
        else { return .unprepared(nil) }
        let total = session.tracks.reduce(0) { $0 + $1.duration }
        var radius: TimeInterval = 0
        while owns(request, until: deadline), radius <= total {
            await enqueue(session: session, around: estimatedBookTime + radius, reason: .handoff, ahead: 30, behind: 0, generation: request)
            if radius > 0 { await enqueue(session: session, around: max(0, estimatedBookTime - radius), reason: .handoff, ahead: 30, behind: 0, generation: request) }
            while owns(request, until: deadline), hasHandoffJobs(of: request) || worker != nil {
                guard let resolution = await resolve() else { return .unprepared(nil) }
                switch resolution {
                case .matched, .notSpoken: return resolution
                case .ambiguous, .unprepared: break
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let resolution = await resolve() else { return .unprepared(nil) }
            switch resolution {
            case .matched, .notSpoken, .ambiguous: return resolution
            case .unprepared: radius += 60
            }
        }
        return .unprepared(nil)
    }

    func cancelExplicitRequests() {
        advanceGeneration()
    }

    /// Starts a new request generation: older handoff searches stop waiting and their queued windows are dropped.
    /// Drops only the windows `request` queued, including a request still waiting for its session; other requests
    /// for the pair keep theirs. A window already being analyzed finishes and is kept.
    func withdrawPreparation(_ request: UUID) {
        if openRequests.contains(request) { withdrawnRequests.insert(request) }
        queue.removeAll { $0.request == request }
    }

    private func advanceGeneration() {
        generation += 1
        let superseded = pendingHandoffWaits.filter { $0.key < generation }
        pendingHandoffWaits = pendingHandoffWaits.filter { $0.key >= generation }
        superseded.values.forEach { $0.values.forEach { $0() } }
        dropObsoleteJobs()
    }

    private func owns(_ request: Int, until deadline: ContinuousClock.Instant) -> Bool {
        request == generation && !Task.isCancelled && !isRetired && ContinuousClock.now < deadline
    }

    private func hasHandoffJobs(of request: Int) -> Bool {
        queue.contains { $0.reason == .handoff && $0.generation == request }
    }

    private func removeHandoffJobs(of request: Int) {
        queue.removeAll { $0.reason == .handoff && $0.generation == request }
    }

    /// Whole-book preparation outlives request generations; every other job belongs to the request that queued it.
    private func isCurrentJob(_ job: WindowJob) -> Bool {
        job.reason == .wholeBook || job.generation == generation
    }

    private func dropObsoleteJobs() {
        queue.removeAll { !isCurrentJob($0) }
    }

    private func enqueue(session: PreparationSession, around bookTime: TimeInterval, reason: PassagePreparationReason, ahead: TimeInterval, behind: TimeInterval, generation requestGeneration: Int, retrying: Bool = false, owner: UUID? = nil) async {
        guard !isRetired, self.session === session else { return }
        let set = if let mappingLoadOverride { await mappingLoadOverride(session.identity) } else { await store.mappingSet(for: session.identity) }
        // Withdrawal, a newer request or a session change during the load makes this request inert.
        guard !isRetired, !Task.isCancelled, self.session === session, owner.map({ !withdrawnRequests.contains($0) }) ?? true,
            reason == .wholeBook || requestGeneration == generation
        else { return }
        let failed = statuses[session.key]?.failedWindows ?? []
        let listeningAhead = reason.isSpeculative && ahead == Self.lookAhead ? session.buffer.listeningSecondsAhead : ahead
        let ranges = [(bookTime, bookTime + listeningAhead * playbackRateFactor), (max(0, bookTime - behind), bookTime)]
        var jobs: [WindowJob] = []
        for (lower, upper) in ranges where upper >= lower {
            for track in session.tracks where track.bookOffset + track.duration > lower && track.bookOffset <= upper {
                let grid = session.grid(track.index)
                let localLower = max(0, lower - track.bookOffset)
                let localUpper = min(track.duration, upper - track.bookOffset)
                // The window owning the current sentence's end comes first; following windows keep reading order.
                for window in grid where window.ownedEndLimit > localLower && window.ownedEndStart <= localUpper + 1 {
                    let ref = PassageWindowRef(trackIndex: track.index, windowIndex: window.index)
                    let attempted = set?.windows.first {
                        $0.trackIndex == track.index && $0.windowIndex == window.index && $0.engine == session.engine.id
                    }
                    guard attempted?.accepted != true, retrying || (attempted == nil && !failed.contains(ref)),
                        !jobs.contains(where: { $0.trackIndex == track.index && $0.window.index == window.index }),
                        !queue.contains(where: { $0.trackIndex == track.index && $0.window.index == window.index })
                    else { continue }
                    jobs.append(WindowJob(trackIndex: track.index, window: window, reason: reason, generation: requestGeneration, request: owner))
                }
            }
        }
        guard !jobs.isEmpty else { return }
        if retrying {
            statuses[session.key]?.failedWindows.subtract(jobs.map { PassageWindowRef(trackIndex: $0.trackIndex, windowIndex: $0.window.index) })
        }
        queue.append(contentsOf: jobs)
        queue = queue.enumerated().sorted { lhs, rhs in
            lhs.element.reason == rhs.element.reason ? lhs.offset < rhs.offset : lhs.element.reason < rhs.element.reason
        }.map(\.element)
        startWorkerIfNeeded()
    }

    private var playbackRateFactor: Double {
        max(1, profileSession.playback.composition.controller.playbackSpeed)
    }

    private func startWorkerIfNeeded() {
        guard worker == nil, closing == nil, clearing == nil, !isStorageBlocked, let next = queue.first, !isRetired, generationEnabled,
            resourceBlocker(for: next.reason) == nil
        else { return }
        worker = Task(priority: .utility) { [weak self] in
            await self?.runQueue()
            self?.worker = nil
            self?.startWorkerIfNeeded()
        }
    }

    private func runQueue() async {
        while !Task.isCancelled, !isRetired, let session {
            dropObsoleteJobs()
            guard let job = queue.first else { break }
            if let blocker = resourceBlocker(for: job.reason) {
                if blocker == .pausedForPower, job.reason.isSpeculative {
                    queue.removeAll { $0.reason.isSpeculative }
                    continue
                }
                setActivity(.paused(blocker), for: session)
                return
            }
            guard await store.enforceAcousticLimit(limit: acousticLimit), await hasFreeSpace() else {
                pauseForStorage(session)
                return
            }
            guard !Task.isCancelled, self.session === session,
                let index = queue.firstIndex(where: { $0.trackIndex == job.trackIndex && $0.window == job.window && $0.generation == job.generation })
            else { continue }
            queue.remove(at: index)
            setActivity(.preparing, for: session)
            let ref = PassageWindowRef(trackIndex: job.trackIndex, windowIndex: job.window.index)
            statuses[session.key]?.analyzing = ref
            defer { if statuses[session.key]?.analyzing == ref { statuses[session.key]?.analyzing = nil } }
            let grid = session.grid(job.trackIndex)
            let previous = job.window.index > 0 ? grid[job.window.index - 1] : nil
            var track = session.tracks[job.trackIndex]
            if !track.url.isFileURL, let media = playbackMedia(ebook: session.ebook, audiobook: session.audiobook) {
                track.headers = media.headers
            }
            let engine = session.engine
            let started = ContinuousClock.now
            let matches: [PassageMatch]
            do {
                matches = try await engine.analyze(window: job.window, previous: previous, track: track)
            } catch is CancellationError {
                // Paused work resumes later; work for a superseded request or a closed session does not.
                if !isRetired, self.session === session, isCurrentJob(job),
                    !queue.contains(where: { $0.trackIndex == job.trackIndex && $0.window == job.window }) {
                    queue.insert(job, at: 0)
                }
                return
            } catch {
                AppLogger.general.warning("[PassageAlignment] Window analysis failed: \(String(describing: type(of: error)))")
                statuses[session.key]?.failedWindows.insert(ref)
                continue
            }
            // A finished inference is valid for its own media identity even if the request moved on.
            guard !isRetired else { return }
            let update = PassageWindowUpdate(
                trackIndex: job.trackIndex, windowIndex: job.window.index,
                ownedEnds: job.window.ownedEndStart..<min(job.window.ownedEndLimit, track.duration + 0.05),
                engine: engine.id, mappings: mappings(from: matches, session: session, track: job.trackIndex)
            )
            do {
                if let set = try await store.commit(update, identity: session.identity) {
                    updateCoverage(set, session: session)
                }
            } catch {
                // The window's checkpoint is kept, so the deliberate retry re-reads it instead of inferring again.
                if self.session === session, isCurrentJob(job),
                    !queue.contains(where: { $0.trackIndex == job.trackIndex && $0.window == job.window }) {
                    queue.insert(job, at: 0)
                }
                pauseForStorage(session)
                return
            }
            guard self.session === session else { return }
            noteContinuedProgress()
            session.analyzedWindows += 1
            let elapsed = (ContinuousClock.now - started).components
            session.buffer.record(
                audioSeconds: min(job.window.ownedEndLimit, track.duration) - job.window.ownedEndStart,
                wallSeconds: Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            )
            // Durations and counts only; the first window's time since startup is the wait before the first highlight.
            let first = session.analyzedWindows == 1 ? " sinceReady=\(ContinuousClock.now - session.readyAt)" : ""
            AppLogger.general.info("[PassageAlignment] Window \(job.window.index) reason=\(job.reason.rawValue) matches=\(update.mappings.count) accepted=\(update.isAccepted) analyzed in \(ContinuousClock.now - started)\(first)")
            try? await Task.sleep(for: await engine.pacing())
        }
        if let session, queue.isEmpty { setActivity(.idle, for: session) }
    }

    private func hasFreeSpace() async -> Bool {
        guard let available = await store.availableCapacity() else { return true }
        return available >= minimumFreeBytes
    }

    /// Low storage keeps queued work but stops relaunching it until a deliberate retry after a delay.
    private func pauseForStorage(_ session: PreparationSession) {
        isStorageBlocked = true
        setActivity(.paused(.lowStorage), for: session)
        storageRetry?.cancel()
        let delay = storageRetryDelay
        storageRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !isRetired else { return }
            isStorageBlocked = false
            storageRetry = nil
            startWorkerIfNeeded()
        }
    }

    private func mappings(from matches: [PassageMatch], session: PreparationSession, track: Int) -> [PassageMapping] {
        Self.mappings(from: matches, sentences: session.sentences, track: track, engine: session.engine.id, granularity: session.engine.granularity)
    }

    /// Quote context comes only from neighbors in the same chapter document, the scope Readium searches.
    nonisolated static func mappings(from matches: [PassageMatch], sentences: [PassageSentence], track: Int, engine: String, granularity: PassageGranularity) -> [PassageMapping] {
        matches.compactMap { match in
            guard sentences.indices.contains(match.sentenceIndex) else { return nil }
            let sentence = sentences[match.sentenceIndex]
            func neighbor(_ index: Int) -> PassageSentence? {
                guard sentences.indices.contains(index) else { return nil }
                let candidate = sentences[index]
                return candidate.key.chapter == sentence.key.chapter && candidate.href == sentence.href ? candidate : nil
            }
            let before = neighbor(match.sentenceIndex - 1).map { String($0.text.suffix(32)) } ?? ""
            let after = neighbor(match.sentenceIndex + 1).map { String($0.text.prefix(32)) } ?? ""
            let words = match.words.flatMap { PassageWordTiming.validated($0, in: sentence.text, start: match.start, end: match.end) }
            return PassageMapping(
                key: sentence.key, href: sentence.href, text: sentence.text, before: before, after: after,
                chapterProgression: sentence.chapterProgression, totalProgression: sentence.totalProgression,
                trackIndex: track, start: match.start, end: match.end, granularity: words == nil ? granularity : .word,
                engine: engine, score: Double(match.score), words: words
            )
        }
    }

    nonisolated static func passageSentences(_ sentences: [CTCPassageSentence]) -> [PassageSentence] {
        sentences.map {
            PassageSentence(key: PassageSentenceKey(chapter: $0.chapter, sentence: $0.sentence), href: $0.href, text: $0.text, chapterProgression: $0.chapterProgression, totalProgression: $0.totalProgression)
        }
    }

    private func setActivity(_ activity: PassagePairStatus.Activity, for session: PreparationSession) {
        var status = statuses[session.key] ?? PassagePairStatus()
        status.activity = activity
        status.engine = session.kind
        status.totalSeconds = session.tracks.reduce(0) { $0 + $1.duration }
        statuses[session.key] = status
    }

    private func updateCoverage(_ set: PassageMappingSet, session: PreparationSession) {
        var status = statuses[session.key] ?? PassagePairStatus()
        status.coveredSeconds = set.coverage.reduce(0) { $0 + ($1.end - $1.start) }
        status.totalSeconds = session.tracks.reduce(0) { $0 + $1.duration }
        statuses[session.key] = status
    }

    /// One shared startup per pair; a stale or other pair's session is torn down first. Every wait, teardown
    /// included, ends at `deadline`, on cancellation, or when `request` is superseded.
    private func openSession(ebook: Book, audiobook: Book, deadline: ContinuousClock.Instant? = nil, request: Int? = nil) async -> PreparationSession? {
        let key = Self.pairKey(ebook: ebook, audiobook: audiobook)
        func wanted() -> Bool {
            !isRetired && clearing == nil && !Task.isCancelled && (request.map { $0 == generation } ?? true)
                && (deadline.map { ContinuousClock.now < $0 } ?? true)
        }
        while wanted() {
            if let closing {
                guard await bounded(closing.task, until: deadline, request: request) != nil else { return nil }
                continue
            }
            if let session, session.key == key {
                // A changed engine preference replaces the session; prepared mappings stay in the store.
                if case .success(let kind) = capability(ebook: ebook, audiobook: audiobook), kind != session.kind {
                    startClosing()
                    continue
                }
                let current = await isCurrentRevision(session)
                guard self.session === session else { continue }
                if current { return session }
                startClosing()
                continue
            }
            if let opening, opening.key == key {
                return await awaitOpening(opening, deadline: deadline, request: request)
            }
            if session != nil || opening != nil {
                startClosing()
                continue
            }
            let token = UUID()
            let task = Task<PreparationSession?, Never> { [weak self] in
                guard let self else { return nil }
                let created = await makeSession(ebook: ebook, audiobook: audiobook, key: key)
                if opening?.token == token {
                    opening = nil
                    if let created, !Task.isCancelled, !isRetired {
                        session = created
                        return created
                    }
                }
                await created?.engine.release()
                return nil
            }
            let started = Opening(key: key, token: token, task: task)
            opening = started
            return await awaitOpening(started, deadline: deadline, request: request)
        }
        return nil
    }

    private func awaitOpening(_ opening: Opening, deadline: ContinuousClock.Instant?, request: Int?) async -> PreparationSession? {
        let created = await bounded(opening.task, until: deadline, request: request)
        guard let created, !isRetired, !Task.isCancelled, session === created else { return nil }
        return created
    }

    /// Waits for a shared task without inheriting its lifetime; nil at the deadline, on cancellation of the
    /// caller, or when `request` is superseded. The task itself keeps running for its other waiters.
    private func bounded<Value: Sendable>(_ task: Task<Value?, Never>, until deadline: ContinuousClock.Instant?, request: Int?) async -> Value? {
        let wait = BoundedWait<Value>()
        let id = UUID()
        if let request { pendingHandoffWaits[request, default: [:]][id] = { wait.resume(nil) } }
        defer { if let request { pendingHandoffWaits[request]?[id] = nil } }
        return await wait.value(of: task, until: deadline)
    }

    private func isCurrentRevision(_ session: PreparationSession) async -> Bool {
        guard let media = playbackMedia(ebook: session.ebook, audiobook: session.audiobook) else { return false }
        let current = await identities.cachedIdentity(
            ebookStableId: session.ebook.stableId, audiobookStableId: session.audiobook.stableId,
            epubURL: media.epub, audioURLs: media.audio, streamSession: media.streamSession
        )
        return current == session.identity
    }

    /// Builds a session off the request path. After cancellation it returns nil without touching pair status.
    private func makeSession(ebook: Book, audiobook: Book, key: String) async -> PreparationSession? {
        let kind: PassageEngineKind
        switch capability(ebook: ebook, audiobook: audiobook) {
        case .success(let selected): kind = selected
        case .failure(let reason):
            statuses[key, default: PassagePairStatus()].activity = .paused(reason)
            return nil
        }
        guard let media = playbackMedia(ebook: ebook, audiobook: audiobook) else { return nil }
        statuses[key, default: PassagePairStatus()].activity = .identifying
        do {
            let request = SessionRequest(key: key, ebook: ebook, audiobook: audiobook, kind: kind, media: media)
            let created: PreparationSession
            if let sessionBuilderOverride {
                created = try await sessionBuilderOverride(request)
            } else {
                created = try await buildSession(request)
            }
            guard !Task.isCancelled, !isRetired else {
                await created.engine.release()
                return nil
            }
            await store.saveTextIndex(created.sentences, identity: created.identity)
            if let set = await store.mappingSet(for: created.identity) { updateCoverage(set, session: created) }
            guard !Task.isCancelled, !isRetired else {
                await created.engine.release()
                return nil
            }
            setActivity(.idle, for: created)
            // A new engine or model gets one fresh attempt at windows that failed in the previous session.
            statuses[key]?.failedWindows = []
            return created
        } catch is CancellationError {
            return nil
        } catch let reason as PassageUnavailableReason {
            if !Task.isCancelled { statuses[key, default: PassagePairStatus()].activity = .paused(reason) }
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            AppLogger.general.warning("[PassageAlignment] Could not start preparation: \(String(describing: type(of: error)))")
            statuses[key, default: PassagePairStatus()].activity = .paused(.preparationFailed)
            return nil
        }
    }

    private func buildSession(_ request: SessionRequest) async throws -> PreparationSession {
        let media = request.media
        let started = ContinuousClock.now
        let identity = try await identities.identity(
            ebookStableId: request.ebook.stableId, audiobookStableId: request.audiobook.stableId, epubURL: media.epub, audioURLs: media.audio, streamSession: media.streamSession
        )
        let identified = ContinuousClock.now
        try Task.checkCancellation()
        statuses[request.key, default: PassagePairStatus()].activity = .loadingEngine
        var tracks: [PassageTrack] = []
        for (index, url) in media.audio.enumerated() {
            let duration = url.isFileURL ? try await AVAssetDuration.load(url) : media.layout[index].duration
            try Task.checkCancellation()
            tracks.append(PassageTrack(index: index, url: url, digest: identity.trackRevisions[index], duration: duration, bookOffset: media.layout[index].startOffset, headers: media.headers, networkSession: profileSession.networkSession))
        }
        let measured = ContinuousClock.now
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let engine: any PassageAlignmentEngine
        let sentences: [CTCPassageSentence]
        // QuartzNet parses the EPUB and loads its model in one analyzer initializer, so only Apple Speech splits them.
        var textIndexed: ContinuousClock.Instant?
        switch request.kind {
        case .quartzNet:
            guard let model = modelDirectoryProvider() else { throw PassageUnavailableReason.modelDownloadRequired }
            let analyzer = try await CTCPassageAnalyzer(
                epubURL: media.epub, modelDirectory: model, workingDirectory: workingDirectory,
                checkpointDirectory: store.acousticDirectory
            )
            engine = QuartzNetPassageEngine(analyzer: analyzer)
            sentences = analyzer.sentences
        case .appleSpeech:
            #if targetEnvironment(macCatalyst)
            throw PassageUnavailableReason.unsupportedSystem
            #else
            guard #available(iOS 26.0, *) else { throw PassageUnavailableReason.unsupportedSystem }
            sentences = try await CTCPassageAnalyzer.sentences(epubURL: media.epub, workingDirectory: workingDirectory)
            textIndexed = ContinuousClock.now
            try Task.checkCancellation()
            do {
                engine = try await AppleSpeechPassageEngine.make(sentences: sentences, language: request.audiobook.language ?? request.ebook.language)
            } catch AudiobookTranscriptionError.speechAuthorizationDenied {
                throw PassageUnavailableReason.permissionDenied
            } catch AudiobookTranscriptionError.localeUnsupported {
                throw PassageUnavailableReason.unsupportedLanguage
            } catch AudiobookTranscriptionError.speechTranscriberUnavailable {
                throw PassageUnavailableReason.unsupportedHardware
            }
            #endif
        }
        try Task.checkCancellation()
        let ready = ContinuousClock.now
        let split = textIndexed.map { " text=\($0 - measured) engine=\(ready - $0)" } ?? " textAndModel=\(ready - measured)"
        // Durations and counts only, for diagnosing startup on device.
        AppLogger.general.info("[PassageAlignment] Session ready engine=\(request.kind.rawValue) identify=\(identified - started) durations=\(measured - identified)\(split) total=\(ready - started) tracks=\(tracks.count) sentences=\(sentences.count)")
        return PreparationSession(
            key: request.key, ebook: request.ebook, audiobook: request.audiobook, identity: identity, tracks: tracks,
            engine: engine, kind: request.kind, sentences: Self.passageSentences(sentences)
        )
    }

    /// Detaches the installed session and any startup at once, then joins them in one teardown task. Openings and
    /// workers wait for that teardown, so engine writers never overlap and nothing detached is installed again.
    @discardableResult
    private func startClosing() -> Task<Bool?, Never> {
        let old = session
        let pending = opening
        let running = worker
        if let old, continuedProcessingPairKey == old.key { endContinuedProcessing(success: false) }
        session = nil
        opening = nil
        queue.removeAll()
        pending?.task.cancel()
        running?.cancel()
        let previous = closing?.task
        let token = UUID()
        let task = Task<Bool?, Never> { [weak self] in
            _ = await previous?.value
            await running?.value
            _ = await pending?.task.value
            await old?.engine.release()
            guard let self else { return true }
            await store.flush()
            if closing?.token == token {
                closing = nil
                startWorkerIfNeeded()
            }
            return true
        }
        closing = (token, task)
        return task
    }

    /// Unbounded close used by unlink and retirement, which must not finish before the old work has stopped.
    private func closeSession() async {
        _ = await startClosing().value
    }

    /// Pauses new inference without discarding queued requests or completed windows.
    func pauseWork(_ reason: PassageUnavailableReason) {
        worker?.cancel()
        if let session { setActivity(.paused(reason), for: session) }
    }

    private func resumeQueuedWork() {
        guard !isRetired, let session else { return }
        if queue.isEmpty {
            setActivity(.idle, for: session)
        } else if isStorageBlocked {
            setActivity(.paused(.lowStorage), for: session)
        } else if let blocker = resourceBlocker(for: queue[0].reason) {
            setActivity(.paused(blocker), for: session)
        } else {
            startWorkerIfNeeded()
        }
    }

    func sceneDidEnterBackground() {
        isInBackground = true
        // A bounded task lets an in-flight window finish its checkpoint and commit, then saves batched mappings.
        let protection = BackgroundCheckpoint()
        protection.begin()
        let running = continuedProcessingGranted ? nil : worker
        if running != nil { pauseWork(.backgroundUnavailable) }
        Task {
            await running?.value
            await store.flush()
            protection.end()
        }
    }

    func sceneDidBecomeActive() {
        isInBackground = false
        environmentDidChange()
    }

    private func environmentDidChange() {
        guard !isRetired, let session else { return }
        if resourceBlocker(for: queue.first?.reason ?? .lookAhead) == nil {
            startWorkerIfNeeded()
        } else if let blocker = resourceBlocker(for: queue.first?.reason ?? .lookAhead), worker != nil {
            if blocker != .pausedForPower { pauseWork(blocker) }
        } else if queue.isEmpty {
            setActivity(.idle, for: session)
        }
    }

    /// Unlinking cancels the pair's work and removes its mappings; both books and their progress are untouched.
    func removePair(ebookStableId: String, audiobookStableId: String) async {
        let key = PassageAlignmentStore.pairKey(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId)
        advanceGeneration()
        mappingsEpoch += 1
        if session?.key == key || opening?.key == key {
            await closeSession()
        } else if let closing {
            // A detached teardown may still be finishing this pair's last window; its commit must land before removal.
            _ = await closing.task.value
        }
        statuses[key] = nil
        await store.removePair(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId)
    }

    /// Joins running work before deleting, so no late commit or cached load survives. Pairs are prepared again on
    /// the next playback or handoff demand; links, positions, originals and analysis data are kept.
    /// Concurrent calls run one after another; demand arriving meanwhile is dropped, not deferred.
    func removePreparedPassages() async {
        let previous = clearing
        let removal = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            advanceGeneration()
            mappingsEpoch += 1
            await closeSession()
            statuses.removeAll()
            await store.removeAll()
            // Anything that started while clearing read the old files and must not be returned afterwards.
            mappingsEpoch += 1
        }
        clearing = removal
        await removal.value
        if clearing == removal { clearing = nil }
    }

    /// Deletes acoustic checkpoints only; prepared passages stay. Running inference rewrites any checkpoint it needs.
    func clearAnalysisData() async {
        await store.clearAcousticCheckpoints()
    }

    func retire() async {
        isRetired = true
        await clearing?.value
        endContinuedProcessing(success: false)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        identityTasks.values.forEach { $0.cancel() }
        identityTasks.removeAll()
        storageRetry?.cancel()
        storageRetry = nil
        let waits = pendingHandoffWaits
        pendingHandoffWaits.removeAll()
        waits.values.forEach { $0.values.forEach { $0() } }
        await closeSession()
        identities.retire()
        await store.retire()
    }

    @ObservationIgnored private(set) var continuedProcessingGranted = false
    @ObservationIgnored private var continuedProcessing: AnyObject?
    @ObservationIgnored private(set) var continuedProcessingPairKey: String?

    /// Explicit, user-initiated preparation of every remaining window. On iOS 26 and later it may continue in
    /// the background only after the system grants a continued-processing task; otherwise it pauses there.
    func prepareWholeBook(ebook: Book, audiobook: Book) {
        guard !isRetired, clearing == nil, generationEnabled else { return }
        Task { [weak self] in
            guard let self, let session = await openSession(ebook: ebook, audiobook: audiobook) else { return }
            let total = session.tracks.reduce(0) { $0 + $1.duration }
            await enqueue(session: session, around: 0, reason: .wholeBook, ahead: total, behind: 0, generation: generation)
            submitContinuedProcessing(for: session)
        }
    }

    private func submitContinuedProcessing(for session: PreparationSession) {
        #if !targetEnvironment(macCatalyst)
        guard #available(iOS 26.0, *), !queue.isEmpty else { return }
        let request = BGContinuedProcessingTaskRequest(
            identifier: PassageContinuedProcessing.identifier, title: "Preparing read along", subtitle: session.ebook.title
        )
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            continuedProcessingPairKey = session.key
        } catch {
            continuedProcessingPairKey = nil
            AppLogger.general.info("[PassageAlignment] Background preparation was not accepted")
        }
        #endif
    }

    /// Whether a granted continued-processing task belongs to this profile's submitted request.
    var claimsContinuedProcessing: Bool {
        !isRetired && continuedProcessingPairKey != nil && continuedProcessingPairKey == session?.key
    }

    #if !targetEnvironment(macCatalyst)
    @available(iOS 26.0, *)
    func handleContinuedProcessingTask(_ task: BGContinuedProcessingTask) {
        guard claimsContinuedProcessing, queue.contains(where: { $0.reason == .wholeBook }) else {
            task.setTaskCompleted(success: false)
            return
        }
        let processing = PassageContinuedProcessing(task: task, total: queue.count)
        continuedProcessing = processing
        continuedProcessingGranted = true
        let key = continuedProcessingPairKey
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.continuedProcessingPairKey == key else { return }
                self.endContinuedProcessing(success: false)
                if self.isInBackground { self.pauseWork(.backgroundUnavailable) }
            }
        }
        startWorkerIfNeeded()
    }
    #endif

    private func noteContinuedProgress() {
        #if !targetEnvironment(macCatalyst)
        guard #available(iOS 26.0, *), let processing = continuedProcessing as? PassageContinuedProcessing else { return }
        let remaining = queue.filter { $0.reason == .wholeBook }.count
        processing.update(remaining: remaining)
        if remaining == 0 { endContinuedProcessing(success: true) }
        #endif
    }

    private func endContinuedProcessing(success: Bool) {
        #if !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *), let processing = continuedProcessing as? PassageContinuedProcessing {
            processing.complete(success: success)
        }
        #endif
        continuedProcessing = nil
        continuedProcessingGranted = false
        continuedProcessingPairKey = nil
    }

    private func ebookURL(_ ebook: Book) -> URL? {
        profileSession.ebooks.resolveExistingLocalEbookURL(bookIdentifier: ebook.id, ebookFileURL: ebook.ebookFileURL, filePath: ebook.filePath)
    }

    private nonisolated static func isEPUB(_ url: URL?) -> Bool {
        url?.pathExtension.lowercased() == "epub"
    }

    struct PassageMedia {
        let epub: URL
        let audio: [URL]
        let layout: [AudioTrackInfo]
        let headers: [String: String]
        let streamSession: String?

        init?(epub: URL, playback: (tracks: [AudioTrackInfo], headers: [String: String], streamSession: String?)) {
            let audio = playback.tracks.compactMap { URL(string: $0.contentUrl) }
            guard !audio.isEmpty, audio.count == playback.tracks.count,
                audio.allSatisfy({ $0.isFileURL || (["http", "https"].contains($0.scheme?.lowercased() ?? "") && playback.streamSession != nil) })
            else { return nil }
            self.epub = epub
            self.audio = audio
            layout = playback.tracks
            headers = playback.headers
            streamSession = playback.streamSession
        }
    }

    private func playbackMedia(ebook: Book, audiobook: Book) -> PassageMedia? {
        guard ebook.mediaType == .ebook, ebook.readAloudSourceStableId == nil, audiobook.mediaType == .audiobook,
            let epub = ebookURL(ebook), Self.isEPUB(epub),
            let playback = profileSession.playback.manager.readAlongPlaybackLayout(for: audiobook)
        else { return nil }
        return PassageMedia(epub: epub, playback: playback)
    }
}

extension PassageUnavailableReason: Error {}

/// Resolves once with whichever comes first: the shared task's value, the deadline, cancellation of the
/// waiting caller, or an explicit `resume`. The shared task itself keeps running.
@MainActor
private final class BoundedWait<Value: Sendable> {
    private var continuation: CheckedContinuation<Value?, Never>?
    private var isResolved = false
    private var timer: Task<Void, Never>?

    func value(of task: Task<Value?, Never>, until deadline: ContinuousClock.Instant?) async -> Value? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !isResolved, !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
                Task { @MainActor in self.resume(await task.value) }
                if let deadline {
                    timer = Task { @MainActor in
                        try? await Task.sleep(until: deadline)
                        self.resume(nil)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in self.resume(nil) }
        }
    }

    func resume(_ value: Value?) {
        isResolved = true
        timer?.cancel()
        timer = nil
        continuation?.resume(returning: value)
        continuation = nil
    }
}

#if !targetEnvironment(macCatalyst)
/// Holds the granted task; constructed only after the system hands one over on iOS 26 or later.
@available(iOS 26.0, *)
@MainActor
private final class PassageContinuedProcessing {
    static let identifier = "com.enve.enve.storyalign"

    private let task: BGContinuedProcessingTask

    init(task: BGContinuedProcessingTask, total: Int) {
        self.task = task
        task.progress.totalUnitCount = Int64(max(total, 1))
    }

    func update(remaining: Int) {
        task.progress.completedUnitCount = max(0, task.progress.totalUnitCount - Int64(remaining))
    }

    func complete(success: Bool) {
        task.expirationHandler = nil
        task.setTaskCompleted(success: success)
    }
}
#endif

@MainActor
private final class BackgroundCheckpoint {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    func begin() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "PassageAlignmentCheckpoint") { [self] in
            end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

private enum AVAssetDuration {
    static func load(_ url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let seconds = try await asset.load(.duration).seconds
        guard seconds.isFinite, seconds > 0 else { throw PassageUnavailableReason.missingMedia }
        return seconds
    }
}
#endif
