#if DEBUG && os(iOS)
import Foundation
import UIKit

/// Measures passage preparation for an existing linked pair at the audiobook's saved position, using only local
/// downloads. Never plays, seeks, links, downloads models or speech assets, or writes progress; the report in
/// `Documents/readalong-linked-probe.json` holds codes, counts and durations only.
@MainActor
enum ReadAlongLinkedPairProbe {
    private static let budget: Duration = .seconds(90)

    private struct Positions: Equatable {
        let ebookProgress: Double
        let ebookLocator: String?
        let ebookUpdated: Date
        let linkedAudiobook: String?
        let audiobookTime: TimeInterval
        let audiobookUpdated: Date
        let storedAudio: TimeInterval?
        let storedAudioUpdated: TimeInterval?
        let playerBook: String?
        let playerPosition: TimeInterval?

        init(ebook: Book, audiobook: Book, profile: ProfileSession) {
            let cache = profile.appState.libraryCache
            let ebook = cache.bookInMemory(uniqueId: ebook.uniqueId) ?? ebook
            let audiobook = cache.bookInMemory(uniqueId: audiobook.uniqueId) ?? audiobook
            let stored = profile.bookProgress.loadProgress(for: audiobook)
            let player = profile.playback.composition.controller.snapshot
            ebookProgress = ebook.canonicalEbookProgress
            ebookLocator = ebook.epubLocator
            ebookUpdated = ebook.lastUpdate
            linkedAudiobook = ebook.linkedAudiobookStableId
            audiobookTime = audiobook.currentTime
            audiobookUpdated = audiobook.lastUpdate
            storedAudio = stored?.progress
            storedAudioUpdated = stored?.lastUpdated
            playerBook = player.currentBook?.stableId
            // A playing player moves on its own; only a paused position must stay put.
            playerPosition = player.isPlaying ? nil : player.position
        }
    }

    static func run(
        titleQuery: String?, engineOverride: String?, downloadCheckOnly: Bool = false, expectedHost: String? = nil,
        quickSyncBudget: Duration? = nil, profile: ProfileSession, engine: EnveEngine
    ) async {
        let output = profile.storage.documentsDirectory.appendingPathComponent("readalong-linked-probe.json")
        // A fresh token per run, so a report left by an earlier run is never mistaken for this one.
        var report: [String: Any] = ["systemVersion": UIDevice.current.systemVersion, "runToken": UUID().uuidString, "runStartedAt": Date().timeIntervalSince1970]
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: output, options: [.atomic, .completeFileProtection])
            }
        }
        guard let titleQuery, !titleQuery.isEmpty else {
            report["result"] = "missingTitleQuery"
            return
        }
        let found = await profile.appState.bookStore.searchBooks(query: titleQuery, limit: 20)
        let candidates = found.filter { $0.mediaType == .ebook && !$0.hasEPUB3MediaOverlay && $0.readAloudSourceStableId == nil }
        report["ebookCandidates"] = candidates.count
        var pair: (ebook: Book, audiobook: Book)?
        for ebook in candidates {
            if let audiobook = await profile.playback.linker.linkedAudiobookAsync(for: ebook) {
                pair = (ebook, audiobook)
                break
            }
        }
        guard let (ebook, audiobook) = pair else {
            report["result"] = "noLinkedPair"
            return
        }
        let before = Positions(ebook: ebook, audiobook: audiobook, profile: profile)
        if let quickSyncBudget {
            report.merge(await quickSync(ebook: ebook, audiobook: audiobook, budget: quickSyncBudget, profile: profile)) { $1 }
            report["positionsUnchanged"] = Positions(ebook: ebook, audiobook: audiobook, profile: profile) == before
            return
        }
        if downloadCheckOnly {
            report.merge(downloadReport(audiobook: audiobook, copies: found.filter { $0.mediaType == .audiobook }, expectedHost: expectedHost, profile: profile)) { $1 }
            report["positionsUnchanged"] = Positions(ebook: ebook, audiobook: audiobook, profile: profile) == before
            report["result"] = "downloadCheck"
            return
        }
        let passages = profile.passageAlignment
        let audioTime = before.storedAudio.map { stored in
            Date(timeIntervalSince1970: before.storedAudioUpdated ?? 0) > before.audiobookUpdated ? stored : before.audiobookTime
        } ?? before.audiobookTime
        report["audiobookTracks"] = audiobook.audioTracks?.count ?? 0
        report["audioFractionAtStart"] = (audiobook.duration ?? 0) > 0 ? audioTime / (audiobook.duration ?? 1) : -1
        report["completeAudioDownloaded"] = profile.downloads.hasCompleteAudio(for: audiobook)
        report["originalEPUBLocal"] = passages.originalEPUBURL(ebook: ebook, audiobook: audiobook) != nil
        report["generationEnabled"] = passages.generationEnabled
        report["cachedMappingsEnabled"] = passages.cachedMappingsEnabled
        report["liveEngine"] = passages.liveEngine?.rawValue ?? "automatic"
        report["appleSpeechSystemAvailable"] = PassageAlignmentService.appleSpeechSystemAvailable
        report["quartzNetModelInstalled"] = StoryAlignModelStore.shared.installedModelDirectory != nil

        // Measuring must not close another pair's session or touch a running conversion.
        let pairKey = PassageAlignmentService.pairKey(ebook: ebook, audiobook: audiobook)
        let otherWork = passages.activeSessionKey.map { $0 != pairKey } ?? false
        if otherWork || (engineOverride != nil && passages.isWorking) {
            report["result"] = "busy"
            report["positionsUnchanged"] = Positions(ebook: ebook, audiobook: audiobook, profile: profile) == before
            return
        }
        let storedEngine = profile.defaults.string(forKey: "passageAlignment.liveEngine")
        let restore = transientEngine(engineOverride, passages: passages, defaults: profile.defaults)
        report["engineOverride"] = restore == nil ? "none" : (engineOverride ?? "none")
        defer {
            if let restore {
                restore()
                report["engineRestored"] = profile.defaults.string(forKey: "passageAlignment.liveEngine") == storedEngine
            }
        }

        let kind: PassageEngineKind
        switch passages.capability(ebook: ebook, audiobook: audiobook) {
        case .success(let selected):
            kind = selected
        case .failure(let reason):
            report["result"] = "unavailable"
            report["reason"] = String(describing: reason)
            report["action"] = action(for: reason)
            return
        }
        report["engine"] = kind.rawValue
        if kind == .appleSpeech, #available(iOS 26.0, *) {
            let readiness = await AudiobookTranscriptionService.shared.passageReadiness(language: audiobook.language ?? ebook.language)
            report["speechReadiness"] = readiness
            guard readiness == "installed" else {
                report["result"] = "speechNotReady"
                report["action"] = readiness == "permissionNotAuthorized"
                    ? "Allow Speech Recognition for Enve in the Settings app"
                    : "Install Apple's speech assets for this language, then run the probe again"
                return
            }
        }

        let started = ContinuousClock.now
        var phases: [[String: Any]] = []
        var lastPhase = ""
        let request = passages.prepare(ebook: ebook, audiobook: audiobook, around: audioTime, reason: .playback)
        // Only this probe's request is withdrawn: on completion, cancellation, retirement or the budget.
        defer { passages.withdrawPreparation(request) }
        var context: PassageAlignmentService.ReadAlongContext?
        var window: PassageWindowRef?
        var firstHighlight: Double?
        while ContinuousClock.now - started < budget, !Task.isCancelled, !profile.isRetired {
            let status = passages.status(ebook: ebook, audiobook: audiobook)
            let phase = phaseCode(status, window: window)
            if phase != lastPhase {
                phases.append(["phase": phase, "at": seconds(ContinuousClock.now - started)])
                lastPhase = phase
            }
            if context == nil { context = await passages.readAlongContext(ebook: ebook, audiobook: audiobook) }
            if window == nil { window = context?.window(at: audioTime) }
            let resolution = await passages.audioResolution(ebook: ebook, audiobook: audiobook, bookTime: audioTime)
            if firstHighlight == nil, resolution.handoffMapping != nil { firstHighlight = seconds(ContinuousClock.now - started) }
            if case .paused = status.activity { break }
            if let window, status.failedWindows.contains(window) { break }
            if let window, status.analyzing != window, !passages.isPending(window, ebook: ebook, audiobook: audiobook),
                let fresh = await passages.readAlongContext(ebook: ebook, audiobook: audiobook),
                fresh.set.windows.contains(where: { $0.trackIndex == window.trackIndex && $0.windowIndex == window.windowIndex })
            {
                context = fresh
                break
            }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
        }
        let timedOut = ContinuousClock.now - started >= budget
        let interrupted = Task.isCancelled || profile.isRetired
        let status = passages.status(ebook: ebook, audiobook: audiobook)
        report["phases"] = phases
        report["elapsed"] = seconds(ContinuousClock.now - started)
        report["timedOut"] = timedOut
        report["firstMappingAtPosition"] = firstHighlight ?? -1
        report["activity"] = phaseCode(status, window: nil)
        report["coveredSeconds"] = status.coveredSeconds
        report["totalSeconds"] = status.totalSeconds
        report["failedWindows"] = status.failedWindows.count

        if let context = await passages.readAlongContext(ebook: ebook, audiobook: audiobook), let window {
            let record = context.set.windows.filter { $0.trackIndex == window.trackIndex && $0.windowIndex == window.windowIndex }
            report["windowAttempted"] = !record.isEmpty
            report["windowAccepted"] = record.contains(where: \.accepted)
            let nearby = context.set.mappings.filter { mapping in
                context.bookTime(of: mapping).map { abs($0 - audioTime) <= 60 } ?? false
            }
            report["mappingsWithin60s"] = nearby.count
            report["wordQualifiedMappings"] = nearby.filter { $0.words != nil }.count
            report["timedWords"] = nearby.reduce(0) { $0 + ($1.words?.count ?? 0) }
            report["printedWords"] = nearby.reduce(0) { $0 + PassageWordMatcher.printedWords($1.text).count }
        }

        let after = Positions(ebook: ebook, audiobook: audiobook, profile: profile)
        report["positionsUnchanged"] = after == before
        report["result"] = interrupted ? "cancelled" : (timedOut ? "budgetExceeded" : "completed")
    }

    /// The user-authorized Quick Sync of a pair whose files are already complete: never downloads, relinks, plays or
    /// seeks, and cancels only its own run. Calibration changes are the intended result; the one before is kept for
    /// rollback. The report holds counts, codes and durations.
    private static func quickSync(ebook: Book, audiobook: Book, budget: Duration, profile: ProfileSession) async -> [String: Any] {
        var report: [String: Any] = ["mode": "quickSync"]
        let service = LinkedBookQuickSyncService.shared
        let ebookFile = profile.passageAlignment.originalEPUBURL(ebook: ebook, audiobook: audiobook)
        guard profile.downloads.hasCompleteAudio(for: audiobook), ebookFile != nil else {
            report["result"] = "filesIncomplete"
            return report
        }
        guard LinkedBookQuickSyncService.isAvailable(for: profile), service.state.map({ $0.isComplete || $0.error != nil }) ?? true else {
            report["result"] = "busy"
            return report
        }
        let audioFiles = profile.localStorage.localAudiobookFilesIfExists(for: audiobook)?.map(\.path)
        let calibration = { profile.linkedProgress.calibrationSummary(ebookStableId: ebook.stableId, audiobookStableId: audiobook.stableId) }
        report["anchorsBefore"] = calibration()?.anchorCount ?? 0

        let started = ContinuousClock.now
        var phases: [[String: Any]] = []
        var lastPhase = ""
        guard let run = service.start(ebook: ebook, audiobook: audiobook, profile: profile) else {
            report["result"] = "notStarted"
            return report
        }
        var final: LinkedBookQuickSyncService.State?
        while ContinuousClock.now - started < budget, !Task.isCancelled, !profile.isRetired {
            guard let state = service.state, state.runID == run else { break }
            let phase = state.error != nil ? "failed" : state.isComplete ? "complete"
                : state.isProvisional ? "checkingProvisional" : state.sampleCount > 0 ? "checking" : "preparing"
            if phase != lastPhase {
                phases.append(["phase": phase, "at": seconds(ContinuousClock.now - started)])
                lastPhase = phase
            }
            final = state
            if state.isComplete || state.error != nil { break }
            do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
        }
        let timedOut = ContinuousClock.now - started >= budget
        if let state = service.state, state.runID == run {
            final = state
            if !state.isComplete, state.error == nil { service.cancel(run: run) }
        }

        report["phases"] = phases
        report["elapsed"] = seconds(ContinuousClock.now - started)
        report["chapterSource"] = final?.chapterSource ?? "unresolved"
        report["chapterMarkers"] = final?.chapterCount ?? 0
        report["chaptersChecked"] = final?.chaptersChecked ?? 0
        report["points"] = final?.sampleCount ?? 0
        report["checked"] = final?.checkedSamples ?? 0
        report["matched"] = final?.matchedSamples ?? 0
        report["acceptedAnchors"] = final?.acceptedAnchors ?? 0
        report["unmatched"] = final?.unmatchedSamples ?? 0
        report["remaining"] = max((final?.sampleCount ?? 0) - (final?.checkedSamples ?? 0), 0)
        report["method"] = final?.method?.rawValue ?? "none"
        report["keptPrevious"] = final?.keptPreviousReason != nil
        let after = calibration()
        report["anchorsAfter"] = after?.anchorCount ?? 0
        report["coverage"] = after?.quality?.coverage ?? 0
        report["largestGap"] = after?.quality?.largestGap ?? 0
        report["evaluatorDefects"] = after?.quality?.defects.map(\.rawValue) ?? []
        report["hasRollback"] = after?.hasPreviousVersion ?? false
        report["fileOwnershipUnchanged"] = profile.localStorage.localAudiobookFilesIfExists(for: audiobook)?.map(\.path) == audioFiles
            && profile.passageAlignment.originalEPUBURL(ebook: ebook, audiobook: audiobook) == ebookFile
        report["result"] = Task.isCancelled || profile.isRetired ? "cancelled"
            : timedOut ? "budgetExceeded"
            : final?.isComplete == true ? "completed" : final?.error != nil ? "failed" : "stopped"
        return report
    }

    /// Read-only: which stored audio the linked audiobook resolves to, the download queue for its key, and which
    /// connection it comes from, as booleans and counts. Connection hosts are compared, never reported.
    private static func downloadReport(audiobook: Book, copies: [Book], expectedHost: String?, profile: ProfileSession) -> [String: Any] {
        let storage = profile.localStorage
        let downloads = profile.downloads
        let key = audiobook.downloadKey
        let ownedKeys = storage.ownedCandidateBookIds(for: audiobook)
        let entries = downloads.tasks.filter { $0.bookId == key }
        let connections = profile.providerConnections.connections
        let linked = connections.first { $0.id == audiobook.providerId }
        func onExpectedHost(_ book: Book) -> Bool {
            guard let expectedHost, let connection = connections.first(where: { $0.id == book.providerId }) else { return false }
            return URL(string: connection.url)?.host?.lowercased() == expectedHost.lowercased()
        }
        let others = copies.filter { $0.stableId != audiobook.stableId }
        var report: [String: Any] = [
            "sourceKind": audiobook.source.rawValue,
            "ownerProfile": profile.isOwner,
            "rawCanonicalComplete": storage.isAudiobookDownloaded(key),
            "ownedComplete": (try? storage.completedAudiobookFiles(for: audiobook)) != nil,
            "hasCompleteAudio": downloads.hasCompleteAudio(for: audiobook),
            "canonicalKeyHasFiles": storage.localAudiobookFilesIfExists(bookId: key)?.isEmpty == false,
            "ownedKeyCount": ownedKeys.count,
            "ownedKeysWithFiles": ownedKeys.filter { storage.localAudiobookFilesIfExists(bookId: $0)?.isEmpty == false }.count,
            "resolvedFileCount": storage.localAudiobookFilesIfExists(for: audiobook)?.count ?? 0,
            "expectedTrackCount": audiobook.audioTracks?.count ?? -1,
            "entriesSameBookKey": entries.count,
            "entryStatuses": entries.map(\.status.rawValue),
            "entryProgress": entries.map { ($0.progress * 100).rounded() / 100 },
            "liveTransfer": downloads.hasLiveTransfer(forBookKey: key),
            "linkedConnectionFound": linked != nil,
            "sameTypeConnections": connections.filter { $0.type == linked?.type }.count,
            "otherAudiobookCopies": others.count,
            "otherCopiesOwnedComplete": others.filter { (try? storage.completedAudiobookFiles(for: $0)) != nil }.count,
        ]
        if let expectedHost {
            report["linkedOnExpectedHost"] = onExpectedHost(audiobook)
            report["expectedHostConnections"] = connections.filter { URL(string: $0.url)?.host?.lowercased() == expectedHost.lowercased() }.count
            report["otherCopiesOnExpectedHost"] = others.filter(onExpectedHost).count
        }
        return report
    }

    /// Applies an explicit engine choice for this run only; the returned closure restores the saved choice,
    /// including its absence.
    private static func transientEngine(_ raw: String?, passages: PassageAlignmentService, defaults: UserDefaults) -> (() -> Void)? {
        guard let raw, let engine = PassageEngineKind(rawValue: raw), engine != passages.liveEngine else { return nil }
        let original = passages.liveEngine
        let stored = defaults.object(forKey: "passageAlignment.liveEngine")
        passages.liveEngine = engine
        return {
            passages.liveEngine = original
            if stored == nil { defaults.removeObject(forKey: "passageAlignment.liveEngine") }
        }
    }

    private static func phaseCode(_ status: PassagePairStatus, window: PassageWindowRef?) -> String {
        switch status.activity {
        case .idle: "idle"
        case .identifying: "identifying"
        case .loadingEngine: "loadingEngine"
        case .preparing: window != nil && status.analyzing == window ? "matchingCurrentWindow" : "preparing"
        case .paused(let reason): "paused.\(reason)"
        }
    }

    private static func action(for reason: PassageUnavailableReason) -> String {
        switch reason {
        case .missingMedia: "Download the ebook and the complete audiobook"
        case .modelDownloadRequired: "Download the English model in StoryAlign settings"
        case .generationDisabled: "Turn on passage preparation in StoryAlign settings"
        case .permissionDenied: "Allow Speech Recognition for Enve in the Settings app"
        default: "none"
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
#endif
