import Foundation
import Logging
import UIKit

@MainActor
@Observable
final class LinkedBookQuickSyncService {
    static let shared = LinkedBookQuickSyncService()

    enum Method: String, Equatable {
        case preparedPassages
        case appleTranscription
        case acousticFingerprint
        case chapterLandmarks
        case proportional

        var displayName: String {
            switch self {
            case .preparedPassages:
                return "Prepared passages"
            case .appleTranscription:
                return "Apple on-device transcription"
            case .acousticFingerprint:
                return "On-device audio matching"
            case .chapterLandmarks:
                return "Chapter landmarks"
            case .proportional:
                return "Approximate progress"
            }
        }
    }

    struct State: Equatable {
        /// The run this state belongs to, so a caller acts only on the run it started.
        let runID: UUID
        let ebookStableId: String
        let audiobookStableId: String
        var stage: String
        var progress: Double
        var matchedSamples: Int
        var sampleCount: Int
        var checkedSamples = 0
        var unmatchedSamples = 0
        var chaptersChecked = 0
        var chapterCount = 0
        /// Where the chapter markers came from: library, download, provider or tracks.
        var chapterSource: String?
        /// A calibration from this run is already in use while the remaining points are checked.
        var isProvisional = false
        /// Anchors in the calibration in use when the run ended; checked points stay counted separately.
        var acceptedAnchors = 0
        var isComplete: Bool
        var error: String?
        var method: Method?
        var keptPreviousReason: String?
    }

    private(set) var state: State?
    @ObservationIgnored private var task: Task<Void, Never>?
    /// A cancelled run's late cleanup, progress or result must not touch a newer run.
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var didDisableIdleTimer = false

    private let sampleDuration: TimeInterval = 24

    private init() {}

    /// Quick Sync reads downloads, ebook text and transcription through app-wide services and saves calibration
    /// to the owner's coordinator, so it runs for the owner profile only. Other profiles keep their own passage
    /// preparation and read along.
    static func isAvailable(for profile: ProfileSession) -> Bool {
        profile.isOwner && !profile.isRetired
    }

    func isRunning(ebook: Book, audiobook: Book) -> Bool {
        guard let state else { return false }
        return state.ebookStableId == ebook.stableId
            && state.audiobookStableId == audiobook.stableId
            && !state.isComplete
            && state.error == nil
    }

    func needsAudiobookDownload(_ audiobook: Book, profile: ProfileSession) -> Bool {
        !profile.downloads.hasCompleteAudio(for: audiobook)
    }

    @discardableResult
    func start(ebook: Book, audiobook: Book, profile: ProfileSession) -> UUID? {
        guard task == nil, Self.isAvailable(for: profile) else { return nil }
        let id = UUID()
        runID = id

        state = State(
            runID: id,
            ebookStableId: ebook.stableId,
            audiobookStableId: audiobook.stableId,
            stage: "Preparing",
            progress: 0,
            matchedSamples: 0,
            sampleCount: 0,
            isComplete: false,
            error: nil,
            method: nil,
            keptPreviousReason: nil
        )
        beginExecutionProtection()

        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if runID == id {
                    task = nil
                    runID = nil
                    endExecutionProtection()
                }
            }
            do {
                try await run(ebook: ebook, audiobook: audiobook, profile: profile, id: id)
            } catch is CancellationError {
                if runID == id { state = nil }
            } catch {
                guard runID == id else { return }
                state?.stage = "Quick Sync failed"
                state?.error = error.localizedDescription
            }
        }
        return id
    }

    /// Stops Quick Sync only, or only the given run; an audiobook download it queued stays in Downloads.
    func cancel(run: UUID? = nil) {
        if let run, run != runID { return }
        LinkedBookLegacyAlignmentService.shared.cancel()
        task?.cancel()
        task = nil
        runID = nil
        state = nil
        endExecutionProtection()
    }

    func dismissResult() {
        guard task == nil else { return }
        state = nil
    }

    private func beginExecutionProtection() {
        guard !UIApplication.shared.isIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        didDisableIdleTimer = true
    }

    private func endExecutionProtection() {
        guard didDisableIdleTimer else { return }
        UIApplication.shared.isIdleTimerDisabled = false
        didDisableIdleTimer = false
    }

    private func run(ebook: Book, audiobook: Book, profile: ProfileSession, id: UUID) async throws {
        try ensureCurrent(profile, run: id)
        if needsAudiobookDownload(audiobook, profile: profile) {
            report(id) { $0.stage = "Downloading audiobook" }
            try await awaitCompleteAudio(for: audiobook, profile: profile) { fraction in
                report(id) {
                    $0.stage = "Downloading audiobook · \(Int(fraction * 100))%"
                    $0.progress = fraction
                }
            }
            try ensureCurrent(profile, run: id)
            report(id) { $0.progress = 0 }
        }

        report(id) {
            $0.stage = "Reading ebook text"
            $0.progress = 0.02
        }
        try await EbookContextService.shared.prepareContext(for: ebook)
        try ensureCurrent(profile, run: id)
        guard let context = EbookContextStore.shared.loadContext(bookStableId: ebook.stableId),
            !context.chunks.isEmpty
        else {
            throw LinkedBookQuickSyncError.emptyEbook
        }

        let index = LinkedBookTextIndex(chunks: context.chunks)
        guard !index.tokens.isEmpty else {
            throw LinkedBookQuickSyncError.emptyEbook
        }

        let tracks = try await AudiobookAudioTimelineResolver.shared.localTracks(for: audiobook)
        try ensureCurrent(profile, run: id)
        let duration = tracks.totalDuration
        guard duration > sampleDuration else {
            throw AudiobookTimelineError.noPlayableAudio
        }

        report(id) {
            $0.stage = "Finding chapter markers"
            $0.progress = 0.05
        }
        let (chapters, chapterSource) = await resolvedChapters(for: audiobook, tracks: tracks, profile: profile)
        try ensureCurrent(profile, run: id)
        report(id) { $0.chapterSource = chapterSource }
        let plan = LinkedBookQuickSyncPlan(chapterStarts: chapters.map(\.start), duration: duration, sampleDuration: sampleDuration)
        let committer = LinkedBookQuickSyncCommitter(profile: profile, ebook: ebook, audiobook: audiobook)
        let prepared = try await preparedAnchors(
            ebook: ebook, audiobook: audiobook, profile: profile,
            at: plan.points.map { min(($0.time + sampleDuration / 2) / duration, 1) }
        )
        try ensureCurrent(profile, run: id)
        report(id) {
            $0.sampleCount = plan.points.count
            $0.chapterCount = plan.chapterCount
        }

        var installedDuringRun = false
        let commitProvisional: ([LinkedBookCalibrationAnchor]) -> Void = { [weak self] anchors in
            guard committer.install(anchors).isAccepted else { return }
            installedDuringRun = true
            self?.report(id) { $0.isProvisional = true }
        }
        // Observations are reused only for the same original EPUB and audio content, by their cached digests.
        var observations: LinkedBookQuickSyncObservations.Store?
        if let epubURL = profile.passageAlignment.originalEPUBURL(ebook: ebook, audiobook: audiobook),
            let media = try? await profile.passageAlignment.identities.identity(
                ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId,
                epubURL: epubURL, audioURLs: tracks.compactMap { URL(string: $0.contentUrl) }
            )
        {
            observations = LinkedBookQuickSyncObservations.Store(
                directory: profile.storage.applicationSupportDirectory.appendingPathComponent("QuickSync", isDirectory: true),
                key: LinkedBookQuickSyncObservations.Key(
                    media: media, duration: duration, sampleDuration: sampleDuration, textTokens: index.tokens.count
                )
            )
        }
        try ensureCurrent(profile, run: id)
        let observe: (LinkedBookQuickSyncPlan.Point) async throws -> LinkedBookCalibrationAnchor?
        if #available(iOS 26.0, *) {
            report(id) { $0.method = .appleTranscription }
            observe = { [weak self] point in
                let window = point.time...(point.time + (self?.sampleDuration ?? 0))
                if let anchor = prepared.first(where: { window.contains($0.audioProgress * duration) }) { return anchor }
                guard let self else { throw CancellationError() }
                return try await transcribedAnchor(at: point, audiobook: audiobook, index: index, duration: duration)
            }
        } else {
            report(id) { $0.method = .preparedPassages }
            observe = { [sampleDuration] point in
                let window = point.time...(point.time + sampleDuration)
                return prepared.first { window.contains($0.audioProgress * duration) }
            }
        }
        let pass = LinkedBookQuickSyncPass(
            plan: plan,
            observe: observe,
            ensureCurrent: { [weak self] in
                guard let self else { throw CancellationError() }
                try ensureCurrent(profile, run: id)
            },
            liveWorkIsBusy: { profile.passageAlignment.isWorking },
            waiting: { [weak self] isWaiting in
                self?.report(id) { $0.stage = isWaiting ? "Waiting while read-along prepares the current passage" : $0.stage }
            },
            record: { observations?.save($0) },
            progress: { [weak self] counts in
                self?.report(id) {
                    $0.stage = "Checking \(min(counts.checked + 1, counts.total)) of \(counts.total) points · "
                        + "\(counts.chaptersChecked) of \(counts.chapterCount) chapter markers"
                    $0.progress = 0.08 + 0.88 * Double(counts.checked) / Double(max(counts.total, 1))
                    $0.checkedSamples = counts.checked
                    $0.matchedSamples = counts.matched
                    $0.unmatchedSamples = counts.unmatched
                    $0.chaptersChecked = counts.chaptersChecked
                }
            },
            commit: commitProvisional
        )
        let outcomes = try await pass.run(cached: observations?.load() ?? [:])
        try ensureCurrent(profile, run: id)
        let anchors = outcomes.compactMap(\.anchor)
        if LinkedBookAlignmentEvaluator.assess(anchors).quality.unitCount >= 4 {
            finish(
                ebook: ebook, audiobook: audiobook, anchors: anchors,
                method: prepared.count == anchors.count ? .preparedPassages : .appleTranscription,
                committer: committer, installedDuringRun: installedDuringRun
            )
            return
        }

        try ensureCurrent(profile, run: id)
        report(id) {
            $0.stage = "Preparing compatibility sync"
            $0.progress = 0.1
            $0.method = .acousticFingerprint
        }
        let fallback = try await LinkedBookLegacyAlignmentService.shared.align(
            chunks: context.chunks,
            tracks: tracks,
            chapters: chapters,
            language: ebook.language ?? audiobook.language
        ) { [weak self] sample, total, matches in
            self?.report(id) {
                $0.stage = "Matching audio sample \(sample) of \(total)"
                $0.progress = 0.12 + 0.8 * Double(sample - 1) / Double(total)
                $0.sampleCount = total
                $0.matchedSamples = matches
            }
        }

        let usableAnchors = LinkedBookAlignmentEvaluator.assess(fallback.anchors).quality.unitCount
        let method: Method
        if usableAnchors >= 2, fallback.acousticMatchCount > 0 {
            method = .acousticFingerprint
        } else if usableAnchors >= 2 {
            method = .chapterLandmarks
        } else {
            method = .proportional
        }
        try ensureCurrent(profile, run: id)
        finish(
            ebook: ebook, audiobook: audiobook, anchors: fallback.anchors, method: method,
            committer: committer, installedDuringRun: installedDuringRun
        )
    }

    /// Prepared passages of the profile that started this run; never those of whichever profile is active later.
    func preparedAnchors(
        ebook: Book, audiobook: Book, profile: ProfileSession, at fractions: [Double]
    ) async throws -> [LinkedBookCalibrationAnchor] {
        try ensureCurrent(profile)
        let anchors = await profile.passageAlignment.calibrationAnchors(ebook: ebook, audiobook: audiobook, at: fractions)
        try ensureCurrent(profile)
        return anchors
    }

    private func ensureCurrent(_ profile: ProfileSession, run id: UUID? = nil) throws {
        try Task.checkCancellation()
        if profile.isRetired { throw CancellationError() }
        if let id, runID != id { throw CancellationError() }
    }

    private func report(_ id: UUID, _ change: (inout State) -> Void) {
        guard runID == id, var current = state else { return }
        change(&current)
        state = current
    }

    /// Joins or queues `profile`'s own download of the audiobook. Cancelling the wait leaves the download running.
    func awaitCompleteAudio(for audiobook: Book, profile: ProfileSession, onProgress: (Double) -> Void) async throws {
        final class Request {
            var isFinished = false
        }
        let downloads = profile.downloads
        let key = audiobook.downloadKey
        guard !downloads.hasCompleteAudio(for: audiobook) else { return }
        if downloads.tasks.contains(where: { $0.bookId == key && $0.isActive && !downloads.hasLiveTransfer(forBookKey: key) }) {
            await downloads.reconcileRestoredTransfers()
            try ensureCurrent(profile)
        }
        let existing = downloads.tasks.filter { $0.bookId == key }
        let earlier = Set(existing.map(\.id))
        // Listed as active with nothing running: `download` clears these, and they are never reported as progress.
        let stale = Set(existing.filter { $0.isActive && !downloads.hasLiveTransfer(forBookKey: key) }.map(\.id))
        let request = Request()
        Task {
            await downloads.download(book: audiobook)
            request.isFinished = true
        }
        var sawTask = false
        // A paused transfer from before is resumed under its own id, so it is followed once it becomes active.
        var watched: String?
        while true {
            try ensureCurrent(profile)
            if watched == nil {
                watched = downloads.tasks.last(where: { task in
                    task.bookId == key && (!earlier.contains(task.id) || (task.isActive && !stale.contains(task.id)))
                })?.id
            }
            if let watched, let task = downloads.tasks.first(where: { $0.id == watched }) {
                sawTask = true
                switch task.status {
                case .queued, .downloading:
                    onProgress(task.progress)
                case .completed:
                    guard downloads.hasCompleteAudio(for: audiobook) else { throw LinkedBookQuickSyncDownloadError.incomplete }
                    return
                case .failed:
                    throw LinkedBookQuickSyncDownloadError.failed(task.errorMessage)
                case .paused:
                    throw LinkedBookQuickSyncDownloadError.paused
                case .cancelled:
                    throw LinkedBookQuickSyncDownloadError.cancelled
                }
            } else if sawTask {
                if downloads.hasCompleteAudio(for: audiobook) { return }
                throw LinkedBookQuickSyncDownloadError.cancelled
            } else if request.isFinished {
                // Refused without queuing, for example offline or with cellular downloads off.
                if downloads.hasCompleteAudio(for: audiobook) { return }
                throw LinkedBookQuickSyncDownloadError.notStarted(downloads.lastError)
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    /// Chapter markers on the player's timeline. A compact library book often has none, so the download's own
    /// metadata, the provider's full details and finally the track boundaries are tried in turn.
    private func resolvedChapters(
        for audiobook: Book, tracks: [AudioTrackInfo], profile: ProfileSession
    ) async -> (chapters: [Chapter], source: String) {
        func usable(_ chapters: [Chapter]?) -> [Chapter]? {
            guard let chapters, chapters.count > 1 else { return nil }
            return chapters
        }
        let cached = profile.appState.libraryCache.bookInMemory(uniqueId: audiobook.uniqueId)
        if let chapters = usable(cached?.chapters) ?? usable(audiobook.chapters) { return (chapters, "library") }
        if let chapters = usable((try? profile.localStorage.loadMetadataOverride(OfflineBookMetadata.self, for: audiobook.downloadKey))?.chapters) {
            return (chapters, "download")
        }
        await profile.catalog.refreshBookDetails(for: audiobook)
        if !profile.isRetired, let chapters = usable(profile.appState.libraryCache.bookInMemory(uniqueId: audiobook.uniqueId)?.chapters) {
            return (chapters, "provider")
        }
        let trackChapters = tracks.map {
            Chapter(id: "track_\($0.index)", start: $0.startOffset, end: $0.startOffset + $0.duration, title: "", index: $0.index)
        }
        return (trackChapters, "tracks")
    }

    @available(iOS 26.0, *)
    private func transcribedAnchor(
        at point: LinkedBookQuickSyncPlan.Point, audiobook: Book, index: LinkedBookTextIndex, duration: TimeInterval
    ) async throws -> LinkedBookCalibrationAnchor? {
        let start = point.time
        let end = min(start + sampleDuration, duration)
        let segments = try await AudiobookTranscriptionService.shared.transcribeWindow(for: audiobook, startTime: start, endTime: end)
            .sorted { $0.startTime < $1.startTime }
        let center = (start + end) / 2
        guard let match = LinkedBookSparseMatcher.match(
            transcript: segments.map(\.text).joined(separator: " "),
            expectedProgress: center / duration,
            in: index
        ) else { return nil }
        let audioTime = segments.isEmpty
            ? center
            : segments.reduce(0) { $0 + ($1.startTime + $1.endTime) / 2 } / Double(segments.count)
        return LinkedBookCalibrationAnchor(
            ebookProgress: match.ebookProgress,
            audioProgress: min(max(audioTime / duration, 0), 1),
            quote: match.quote,
            href: match.href,
            confidence: match.confidence
        )
    }

    private func finish(
        ebook: Book,
        audiobook: Book,
        anchors: [LinkedBookCalibrationAnchor],
        method: Method,
        committer: LinkedBookQuickSyncCommitter,
        installedDuringRun: Bool
    ) {
        let decision = committer.install(anchors)
        let summary = committer.summary
        let keptPrevious = !decision.isAccepted && !installedDuringRun && summary != nil

        state?.stage = keptPrevious ? "Kept the existing calibration" : "Quick Sync ready"
        state?.progress = 1
        state?.acceptedAnchors = summary?.anchorCount ?? 0
        state?.isProvisional = false
        state?.isComplete = true
        state?.method = method
        state?.keptPreviousReason = keptPrevious ? decision.explanation : nil
        AppLogger.general.info(
            "Quick Sync completed with \(method.displayName): \(decision.explanation)"
        )
    }

}

/// The calibration target fixed when a run starts: that profile's coordinator and the calibration it had then, kept
/// for rollback. Later installs never look up the active profile.
@MainActor
struct LinkedBookQuickSyncCommitter {
    let calibrations: LinkedBookProgressCoordinator
    let ebookStableId: String
    let audiobookStableId: String
    let rollback: LinkedBookCalibrationVersions

    init(profile: ProfileSession, ebook: Book, audiobook: Book) {
        calibrations = profile.linkedProgress
        ebookStableId = ebook.stableId
        audiobookStableId = audiobook.stableId
        rollback = calibrations.calibration(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId)
    }

    @discardableResult
    func install(_ anchors: [LinkedBookCalibrationAnchor]) -> LinkedBookAlignmentDecision {
        calibrations.installCalibration(
            ebookStableId: ebookStableId, audiobookStableId: audiobookStableId, anchors: anchors, keepingRollback: rollback
        )
    }

    var summary: LinkedBookProgressCoordinator.CalibrationSummary? {
        calibrations.calibrationSummary(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId)
    }
}

/// Where Quick Sync listens: shortly after every chapter marker, where speech usually starts, and at regular points
/// inside long chapters. Markers too close to share a window are checked together and each still counts.
struct LinkedBookQuickSyncPlan: Equatable {
    struct Point: Codable, Equatable, Hashable, Sendable {
        let time: TimeInterval
        let chapters: [Int]
    }

    static let speechLead: TimeInterval = 2
    static let interiorSpacing: TimeInterval = 600

    let points: [Point]
    let chapterCount: Int

    init(chapterStarts: [TimeInterval], duration: TimeInterval, sampleDuration: TimeInterval) {
        let latest = max(duration - sampleDuration, 0)
        let markers = chapterStarts.enumerated()
            .filter { $0.element.isFinite && $0.element >= 0 && $0.element < duration }
            .sorted { $0.element < $1.element }
        var points: [Point] = []
        func add(_ time: TimeInterval, chapter: Int?) {
            let time = min(max(time, 0), latest)
            if let last = points.last, time - last.time < sampleDuration / 2 {
                if let chapter { points[points.count - 1] = Point(time: last.time, chapters: last.chapters + [chapter]) }
                return
            }
            points.append(Point(time: time, chapters: chapter.map { [$0] } ?? []))
        }
        let spans = markers.isEmpty ? [(offset: -1, element: 0.0)] : markers
        for (position, marker) in spans.enumerated() {
            let end = position + 1 < spans.count ? spans[position + 1].element : duration
            add(marker.element + Self.speechLead, chapter: marker.offset >= 0 ? marker.offset : nil)
            var interior = marker.element + Self.interiorSpacing
            while interior < end - sampleDuration {
                add(interior, chapter: nil)
                interior += Self.interiorSpacing
            }
        }
        self.points = points
        chapterCount = markers.count
    }
}

/// Checks every planned point in order, reusing earlier observations, and offers the improving calibration at each
/// batch so it can be used while the rest are checked.
@MainActor
struct LinkedBookQuickSyncPass {
    struct Outcome: Codable, Equatable {
        let point: LinkedBookQuickSyncPlan.Point
        let anchor: LinkedBookCalibrationAnchor?
    }

    struct Counts: Equatable {
        var checked = 0
        var matched = 0
        var unmatched = 0
        var total = 0
        var chaptersChecked = 0
        var chapterCount = 0
    }

    static let batch = 8

    let plan: LinkedBookQuickSyncPlan
    let observe: (LinkedBookQuickSyncPlan.Point) async throws -> LinkedBookCalibrationAnchor?
    let ensureCurrent: () throws -> Void
    /// Live read-along preparation for the current passage goes first; no point is checked while it runs.
    let liveWorkIsBusy: () -> Bool
    let waiting: (Bool) -> Void
    let record: (Outcome) -> Void
    let progress: (Counts) -> Void
    let commit: ([LinkedBookCalibrationAnchor]) -> Void

    func run(cached: [LinkedBookQuickSyncPlan.Point: Outcome]) async throws -> [Outcome] {
        var counts = Counts(total: plan.points.count, chapterCount: plan.chapterCount)
        var outcomes: [Outcome] = []
        var committedMatches = 0
        progress(counts)
        for point in plan.points {
            try ensureCurrent()
            let outcome: Outcome
            if let earlier = cached[point], earlier.anchor != nil {
                outcome = earlier
            } else {
                if liveWorkIsBusy() {
                    waiting(true)
                    while liveWorkIsBusy() {
                        try await Task.sleep(for: .milliseconds(250))
                        try ensureCurrent()
                    }
                    waiting(false)
                }
                do {
                    outcome = Outcome(point: point, anchor: try await observe(point))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try ensureCurrent()
                    AppLogger.general.info("Quick Sync transcription unavailable; using compatibility sync")
                    return []
                }
                try ensureCurrent()
                record(outcome)
            }
            outcomes.append(outcome)
            counts.checked += 1
            counts.chaptersChecked += point.chapters.count
            if outcome.anchor == nil { counts.unmatched += 1 } else { counts.matched += 1 }
            progress(counts)
            if counts.checked % Self.batch == 0, counts.matched > committedMatches,
                LinkedBookAlignmentEvaluator.assess(outcomes.compactMap(\.anchor)).quality.unitCount >= 4
            {
                committedMatches = counts.matched
                commit(outcomes.compactMap(\.anchor))
            }
        }
        return outcomes
    }
}

/// Earlier observations of one pair's audio and text, so a restarted Quick Sync checks only what is left.
enum LinkedBookQuickSyncObservations {
    struct Key: Codable, Equatable {
        static let version = 2
        var version = Key.version
        let media: PassageMediaIdentity
        let duration: TimeInterval
        let sampleDuration: TimeInterval
        let textTokens: Int
    }

    private struct File: Codable {
        let key: Key
        var outcomes: [LinkedBookQuickSyncPass.Outcome]
    }

    @MainActor
    final class Store {
        private let url: URL
        private let key: Key
        private var outcomes: [LinkedBookQuickSyncPass.Outcome] = []

        init(directory: URL, key: Key) {
            self.key = key
            url = directory.appendingPathComponent(
                PassageAlignmentStore.pairKey(ebookStableId: key.media.ebookStableId, audiobookStableId: key.media.audiobookStableId) + ".json"
            )
        }

        func load() -> [LinkedBookQuickSyncPlan.Point: LinkedBookQuickSyncPass.Outcome] {
            guard let data = try? Data(contentsOf: url),
                let file = try? JSONDecoder().decode(File.self, from: data),
                file.key.version == key.version, file.key.media == key.media, abs(file.key.duration - key.duration) < 0.5,
                file.key.sampleDuration == key.sampleDuration, file.key.textTokens == key.textTokens
            else { return [:] }
            outcomes = file.outcomes
            return Dictionary(file.outcomes.map { ($0.point, $0) }, uniquingKeysWith: { _, latest in latest })
        }

        func save(_ outcome: LinkedBookQuickSyncPass.Outcome) {
            if let index = outcomes.firstIndex(where: { $0.point == outcome.point }) {
                outcomes[index] = outcome
            } else {
                outcomes.append(outcome)
            }
            guard let data = try? JSONEncoder().encode(File(key: key, outcomes: outcomes)) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}

enum LinkedBookQuickSyncDownloadError: LocalizedError, Equatable {
    case notStarted(String?)
    case failed(String?)
    case paused
    case cancelled
    case incomplete

    var errorDescription: String? {
        switch self {
        case .notStarted(let reason):
            "The audiobook download could not start\(reason.map { ": \($0)" } ?? ""). Quick Sync needs the audiobook on this device."
        case .failed(let reason):
            reason.map { "The audiobook download failed: \($0)" } ?? "The audiobook download failed."
        case .paused:
            "The audiobook download is paused. Resume it in Downloads, then run Quick Sync again."
        case .cancelled:
            "The audiobook download was cancelled."
        case .incomplete:
            "The audiobook download finished without complete audio. Download it again, then run Quick Sync."
        }
    }
}

struct LinkedBookTextIndex {
    struct Token {
        let value: String
        let chunkIndex: Int
        let localIndex: Int
    }

    let chunks: [EbookContextChunk]
    let wordsByChunk: [[String]]
    let tokens: [Token]
    let positionsByWord: [String: [Int]]

    init(chunks: [EbookContextChunk]) {
        self.chunks = chunks
        wordsByChunk = chunks.map { LinkedBookSparseMatcher.words(in: $0.text) }

        var builtTokens: [Token] = []
        for (chunkIndex, words) in wordsByChunk.enumerated() {
            builtTokens.append(
                contentsOf: words.enumerated().map {
                    Token(value: $0.element, chunkIndex: chunkIndex, localIndex: $0.offset)
                }
            )
        }
        tokens = builtTokens
        positionsByWord = Dictionary(grouping: builtTokens.indices, by: { builtTokens[$0].value })
    }
}

enum LinkedBookSparseMatcher {
    struct Match {
        let ebookProgress: Double
        let quote: String
        let href: String?
        let confidence: Double
    }

    static func match(
        transcript: String,
        expectedProgress: Double,
        in index: LinkedBookTextIndex,
        requiresUniquePassage: Bool = false
    ) -> Match? {
        let query = words(in: transcript)
        guard query.count >= 8 else { return nil }

        var votes: [Int: Int] = [:]
        for (queryIndex, word) in query.enumerated() {
            guard word.count >= 4,
                let positions = index.positionsByWord[word],
                positions.count <= 20
            else { continue }
            for position in positions {
                let estimatedStart = position - queryIndex
                votes[estimatedStart / 4, default: 0] += 1
            }
        }

        let expectedStart = Int(expectedProgress * Double(max(index.tokens.count - query.count, 0)))
        var candidateStarts =
            votes
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return abs(lhs.key * 4 - expectedStart) < abs(rhs.key * 4 - expectedStart)
                }
                return lhs.value > rhs.value
            }
            .prefix(30)
            .map { $0.key * 4 }
        candidateStarts.append(expectedStart)

        let scored = Set(candidateStarts).compactMap { start -> ScoredMatch? in
            score(query: query, candidateStart: start, index: index)
        }.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 0.0001 {
                return lhs.score > rhs.score
            }
            return abs(lhs.centerProgress - expectedProgress) < abs(rhs.centerProgress - expectedProgress)
        }

        guard let best = scored.first else { return nil }
        let runnerUp = scored.dropFirst().first {
            abs($0.centerToken - best.centerToken) > query.count
        }
        let margin = best.score - (runnerUp?.score ?? 0)
        if requiresUniquePassage, best.score < 0.72 || margin < 0.12 { return nil }
        guard best.score >= 0.38,
            margin >= 0.025 || best.score >= 0.58
        else {
            return nil
        }

        let token = index.tokens[best.centerToken]
        let chunk = index.chunks[token.chunkIndex]
        let chunkWords = index.wordsByChunk[token.chunkIndex]
        let quoteStart = max(0, token.localIndex - 5)
        let quoteEnd = min(chunkWords.count, quoteStart + 12)
        guard quoteEnd > quoteStart else { return nil }

        let localFraction = Double(token.localIndex) / Double(max(chunkWords.count - 1, 1))
        let ebookProgress = min(
            max(
                chunk.startProgress + localFraction * (chunk.endProgress - chunk.startProgress),
                0
            ),
            1
        )
        let confidence = min(1, best.score + min(max(margin, 0), 0.15))
        let wordRanges = chunk.text.ranges(of: /[\p{L}\p{N}]+/)
        let quote = requiresUniquePassage && wordRanges.count == chunkWords.count
            ? String(chunk.text[wordRanges[quoteStart].lowerBound..<wordRanges[quoteEnd - 1].upperBound])
            : chunkWords[quoteStart..<quoteEnd].joined(separator: " ")
        return Match(
            ebookProgress: ebookProgress,
            quote: quote,
            href: chunk.href,
            confidence: confidence
        )
    }

    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private struct ScoredMatch {
        let score: Double
        let centerToken: Int
        let centerProgress: Double
    }

    private static func score(
        query: [String],
        candidateStart: Int,
        index: LinkedBookTextIndex
    ) -> ScoredMatch? {
        let lower = max(0, candidateStart - 12)
        let upper = min(index.tokens.count, candidateStart + query.count + 24)
        guard upper > lower else { return nil }
        let candidate = index.tokens[lower..<upper].map(\.value)

        var table = Array(
            repeating: Array(repeating: 0, count: candidate.count + 1),
            count: query.count + 1
        )
        for queryIndex in 1...query.count {
            for candidateIndex in 1...candidate.count {
                if query[queryIndex - 1] == candidate[candidateIndex - 1] {
                    table[queryIndex][candidateIndex] = table[queryIndex - 1][candidateIndex - 1] + 1
                } else {
                    table[queryIndex][candidateIndex] = max(
                        table[queryIndex - 1][candidateIndex],
                        table[queryIndex][candidateIndex - 1]
                    )
                }
            }
        }

        let matchedCount = table[query.count][candidate.count]
        guard matchedCount > 0 else { return nil }

        var queryIndex = query.count
        var candidateIndex = candidate.count
        var matchedPositions: [Int] = []
        while queryIndex > 0, candidateIndex > 0 {
            if query[queryIndex - 1] == candidate[candidateIndex - 1] {
                matchedPositions.append(lower + candidateIndex - 1)
                queryIndex -= 1
                candidateIndex -= 1
            } else if table[queryIndex - 1][candidateIndex] >= table[queryIndex][candidateIndex - 1] {
                queryIndex -= 1
            } else {
                candidateIndex -= 1
            }
        }

        guard !matchedPositions.isEmpty else { return nil }
        let centerToken = matchedPositions[matchedPositions.count / 2]
        return ScoredMatch(
            score: Double(matchedCount) / Double(query.count),
            centerToken: centerToken,
            centerProgress: Double(centerToken) / Double(max(index.tokens.count - 1, 1))
        )
    }
}
