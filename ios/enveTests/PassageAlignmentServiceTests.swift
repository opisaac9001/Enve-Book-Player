import Foundation
import StoryAlignCore
import Testing
@testable import enve

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct PassageAlignmentServiceTests {
    @Test func concurrentRequestsShareOneStartupAndSupersessionReturnsPromptly() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let first = Task { await fixture.service.findReadingPosition(ebook: fixture.ebook, audiobook: fixture.audiobook, playhead: { 30 }) }
        try await fixture.until { fixture.builds == 1 }
        let second = Task { await fixture.service.findReadingPosition(ebook: fixture.ebook, audiobook: fixture.audiobook, playhead: { 30 }) }

        let started = ContinuousClock.now
        #expect(await first.value == .unprepared)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(fixture.builds == 1)

        fixture.engine.finishWork()
        fixture.startup.open()
        #expect(await second.value == .unprepared)
        #expect(fixture.builds == 1)
        #expect(fixture.service.activeSessionKey == fixture.key)
        await fixture.session.retire()
    }

    @Test func unlinkDuringStartupNeverInstallsTheSession() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // Hashing and model setup can finish after cancellation; the late result must still be discarded.
        fixture.startupIgnoresCancellation = true
        let search = Task { await fixture.service.findReadingPosition(ebook: fixture.ebook, audiobook: fixture.audiobook, playhead: { 30 }) }
        try await fixture.until { fixture.startupWaits == 1 }

        let unlink = Task { await fixture.service.removePair(ebookStableId: fixture.ebook.stableId, audiobookStableId: fixture.audiobook.stableId) }
        #expect(await search.value == .unprepared)
        try await Task.sleep(for: .milliseconds(100))
        fixture.startup.open()
        await unlink.value
        #expect(fixture.service.activeSessionKey == nil)
        #expect(fixture.service.queuedWindows.isEmpty)
        #expect(fixture.engine.releases == 1)
        await fixture.session.retire()
    }

    @Test func retirementCancelsAndJoinsAStartupInProgress() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        try await fixture.until { fixture.startupWaits == 1 }

        await fixture.service.retire()
        #expect(fixture.startupCancellations == 1)
        fixture.startup.open()
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.service.activeSessionKey == nil)
        #expect(fixture.service.queuedWindows.isEmpty)
        await fixture.session.retire()
    }

    @Test func replacedAudioRevisionReplacesTheInstalledSession() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.startup.open()
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        try await fixture.until { fixture.service.activeSessionKey != nil }
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 300, reason: .playback)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.builds == 1)

        try Data(repeating: 9, count: 130_000).write(to: fixture.audio)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(120)], ofItemAtPath: fixture.audio.path)
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        try await fixture.until { fixture.builds == 2 && fixture.service.activeSessionKey != nil }
        #expect(fixture.builtIdentities.count == 2)
        #expect(fixture.builtIdentities[0].trackRevisions != fixture.builtIdentities[1].trackRevisions)
        await fixture.session.retire()
    }

    @Test func handoffBudgetIncludesStartupAndLeavesNoLateWork() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let started = ContinuousClock.now
        let result = await fixture.service.findReadingPosition(
            ebook: fixture.ebook, audiobook: fixture.audiobook, playhead: { 30 }, budget: .milliseconds(300)
        )
        #expect(result == .unprepared)
        #expect(ContinuousClock.now - started < .seconds(2))

        // The shared startup may still finish and be reused later, but the expired request queues nothing.
        fixture.startup.open()
        try await fixture.until { fixture.service.activeSessionKey != nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.service.queuedWindows.isEmpty)
        #expect(fixture.engine.calls == 0)
        await fixture.session.retire()
    }

    @Test func cancelledHandoffReturnsPromptlyDuringStartup() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let search = Task { await fixture.service.findReadingPosition(ebook: fixture.ebook, audiobook: fixture.audiobook, playhead: { 30 }) }
        try await fixture.until { fixture.builds == 1 }
        let started = ContinuousClock.now
        search.cancel()
        #expect(await search.value == .unprepared)
        #expect(ContinuousClock.now - started < .seconds(1))
        await fixture.session.retire()
    }

    @Test func supersededListeningSearchStopsAndDropsItsQueuedWindows() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.startup.open()
        let search = Task {
            await fixture.service.findListeningPosition(
                ebook: fixture.ebook, audiobook: fixture.audiobook, href: "OEBPS/c1.xhtml", quote: "A sentence nobody narrates here.",
                chapterProgression: nil, estimatedBookTime: 100
            )
        }
        try await fixture.until { fixture.engine.calls == 1 }
        #expect(fixture.service.queuedWindows.contains { $0.reason == .handoff })

        let started = ContinuousClock.now
        fixture.service.cancelExplicitRequests()
        #expect(await search.value == .unprepared(nil))
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(!fixture.service.queuedWindows.contains { $0.reason == .handoff })

        fixture.engine.finishWork()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!fixture.service.queuedWindows.contains { $0.reason == .handoff })
        #expect(fixture.engine.calls == 1)
        await fixture.session.retire()
    }

    @Test func lowStoragePausesUntilADeliberateRetry() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.startup.open()
        let acoustic = fixture.service.store.acousticDirectory
        try FileManager.default.createDirectory(at: acoustic, withIntermediateDirectories: true)
        try Data(count: 4_096).write(to: acoustic.appendingPathComponent("pinned-by-permissions.plist"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: acoustic.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acoustic.path) }
        fixture.service.acousticLimit = 0
        fixture.service.storageRetryDelay = .milliseconds(600)
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)

        try await fixture.until { fixture.service.status(ebook: fixture.ebook, audiobook: fixture.audiobook).activity == .paused(.lowStorage) }
        for _ in 0..<4 {
            #expect(!fixture.service.isWorking)
            #expect(!fixture.service.queuedWindows.isEmpty)
            try await Task.sleep(for: .milliseconds(80))
        }
        #expect(fixture.engine.calls == 0)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: acoustic.path)
        fixture.service.acousticLimit = PassageAlignmentStore.acousticLimitBytes
        try await fixture.until { fixture.engine.calls > 0 }
        await fixture.session.retire()
    }

    @Test func staleQueuedWorkIsDroppedAndCancelledStaleWorkIsNotRequeued() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.startup.open()
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .lookAhead)
        try await fixture.until { fixture.engine.calls == 1 }
        #expect(fixture.service.queuedWindows.contains { $0.reason == .lookAhead })

        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 400, reason: .playback)
        try await fixture.until { fixture.service.queuedWindows.contains { $0.reason == .playback } }
        #expect(!fixture.service.queuedWindows.contains { $0.reason == .lookAhead })

        // Cancelling the in-flight look-ahead window must not put superseded work back in the queue.
        fixture.service.pauseWork(.pausedForTemperature)
        try await Task.sleep(for: .milliseconds(200))
        #expect(!fixture.service.queuedWindows.contains { $0.reason == .lookAhead })
        await fixture.session.retire()
    }

    @Test func anotherPairsStalledStartupCannotHoldAHandoffPastItsBudget() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.startupIgnoresCancellation = true
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        try await fixture.until { fixture.builds == 1 }
        let other = try fixture.makePair("other")

        let started = ContinuousClock.now
        let result = await fixture.service.findReadingPosition(
            ebook: other.ebook, audiobook: other.audiobook, playhead: { 30 }, budget: .milliseconds(300)
        )
        #expect(result == .unprepared)
        #expect(ContinuousClock.now - started < .milliseconds(900))
        #expect(fixture.builds == 1)
        #expect(fixture.service.activeSessionKey == nil)

        // The stale startup drains into a release, never an installed session, before the next pair may open.
        fixture.startup.open()
        try await fixture.until { fixture.engine.releases == 1 }
        #expect(fixture.service.activeSessionKey == nil)
        let otherKey = PassageAlignmentService.pairKey(ebook: other.ebook, audiobook: other.audiobook)
        fixture.service.prepare(ebook: other.ebook, audiobook: other.audiobook, around: 0, reason: .playback)
        try await fixture.until { fixture.service.activeSessionKey == otherKey }
        #expect(fixture.builds == 2)
        #expect(fixture.engine.releases == 1)
        await fixture.session.retire()
    }

    @Test func anotherPairsStalledWorkerCannotHoldAHandoffPastItsBudget() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.startup.open()
        fixture.engine.ignoresCancellation = true
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        try await fixture.until { fixture.engine.calls == 1 }
        let other = try fixture.makePair("other")

        let started = ContinuousClock.now
        let result = await fixture.service.findReadingPosition(
            ebook: other.ebook, audiobook: other.audiobook, playhead: { 30 }, budget: .milliseconds(300)
        )
        #expect(result == .unprepared)
        #expect(ContinuousClock.now - started < .milliseconds(900))
        #expect(fixture.builds == 1)
        #expect(fixture.service.isWorking)

        // No second engine writer starts while the detached one is still analyzing.
        let otherKey = PassageAlignmentService.pairKey(ebook: other.ebook, audiobook: other.audiobook)
        fixture.service.prepare(ebook: other.ebook, audiobook: other.audiobook, around: 0, reason: .playback)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.builds == 1)
        #expect(fixture.engine.calls == 1)

        fixture.engine.ignoresCancellation = false
        fixture.engine.finishWork()
        try await fixture.until { fixture.service.activeSessionKey == otherKey }
        #expect(fixture.engine.releases == 1)
        #expect(fixture.builds == 2)
        await fixture.session.retire()
    }

    @Test func cancellingAHandoffWhileAnotherPairTearsDownReturnsPromptly() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.startupIgnoresCancellation = true
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        try await fixture.until { fixture.builds == 1 }
        let other = try fixture.makePair("other")
        let search = Task { await fixture.service.findReadingPosition(ebook: other.ebook, audiobook: other.audiobook, playhead: { 30 }) }
        try await Task.sleep(for: .milliseconds(150))

        let started = ContinuousClock.now
        search.cancel()
        #expect(await search.value == .unprepared)
        #expect(ContinuousClock.now - started < .seconds(1))

        fixture.startup.open()
        try await fixture.until { fixture.engine.releases == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.builds == 1)
        #expect(fixture.service.activeSessionKey == nil)
        await fixture.session.retire()
    }

    @Test func lateCachedResolutionNeverSupersedesANewerRequest() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()

        // A fresh service reads identity and mappings from disk, so each request suspends in its cached lookup.
        let reading = PassageAlignmentService(profileSession: fixture.session)
        let olderReading = Task { await reading.findReadingPosition(ebook: fixture.ebook, audiobook: fixture.audiobook, playhead: { 12 }) }
        let newerReading = Task { await reading.findReadingPosition(ebook: fixture.ebook, audiobook: fixture.audiobook, playhead: { 12 }) }
        #expect(await olderReading.value == .unprepared)
        #expect(await newerReading.value.handoffMapping != nil)
        await reading.retire()

        let listening = PassageAlignmentService(profileSession: fixture.session)
        let olderListening = Task { await fixture.findNarratedSentence(with: listening) }
        let newerListening = Task { await fixture.findNarratedSentence(with: listening) }
        #expect(await olderListening.value == .unprepared(nil))
        #expect(await newerListening.value.isMatched)
        await listening.retire()
        await fixture.session.retire()
    }

    @Test func cancelledOrExpiredRequestsNeverReturnACachedMatch() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        let service = fixture.service!

        let reading = Task { await service.findReadingPosition(ebook: fixture.ebook, audiobook: fixture.audiobook, playhead: { 12 }) }
        reading.cancel()
        #expect(await reading.value == .unprepared)
        let listening = Task { await fixture.findNarratedSentence(with: service) }
        listening.cancel()
        #expect(await listening.value == .unprepared(nil))
        #expect(await service.findReadingPosition(ebook: fixture.ebook, audiobook: fixture.audiobook, playhead: { 12 }, budget: .zero) == .unprepared)
        #expect(await fixture.findNarratedSentence(with: service, budget: .zero) == .unprepared(nil))

        #expect(await service.findReadingPosition(ebook: fixture.ebook, audiobook: fixture.audiobook, playhead: { 12 }).handoffMapping != nil)
        #expect(await fixture.findNarratedSentence(with: service).isMatched)
        await fixture.session.retire()
    }

    @Test func switchingPreparedPassagesOffWithholdsResolutionsInFlightAndOnRestoresThemWithoutAnEngine() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()

        // A fresh service reads identity and mappings from disk, so the resolution is suspended when the switch flips.
        let service = PassageAlignmentService(profileSession: fixture.session)
        service.modelDirectoryProvider = { nil }
        let pending = Task { await service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12) }
        await Task.yield()
        service.cachedMappingsEnabled = false
        #expect(await pending.value == .unprepared)
        #expect(await service.readAlongContext(ebook: fixture.ebook, audiobook: fixture.audiobook) == nil)
        #expect(await fixture.findNarratedSentence(with: service) == .unprepared(nil))

        service.cachedMappingsEnabled = true
        service.generationEnabled = false
        #expect(service.capability(ebook: fixture.ebook, audiobook: fixture.audiobook) == .failure(.generationDisabled))
        #expect(await service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12).handoffMapping != nil)
        #expect(await service.textResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, href: Fixture.narratedHref, quote: Fixture.narrated, chapterProgression: 0.1).isMatched)
        service.generationEnabled = true
        await service.retire()
        await fixture.session.retire()
    }

    @Test func generationOffPausesQueuedWorkAndOnResumesIt() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.startup.open()
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        try await fixture.until { fixture.engine.calls == 1 }

        fixture.service.generationEnabled = false
        try await fixture.until { !fixture.service.isWorking }
        #expect(fixture.service.status(ebook: fixture.ebook, audiobook: fixture.audiobook).activity == .paused(.generationDisabled))
        #expect(!fixture.service.queuedWindows.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.engine.calls == 1)

        fixture.service.generationEnabled = true
        try await fixture.until { fixture.engine.calls == 2 }
        #expect(fixture.service.status(ebook: fixture.ebook, audiobook: fixture.audiobook).activity == .preparing)
        await fixture.session.retire()
    }

    @Test func removingPreparedPassagesDuringAWindowLeavesNothingBehindUntilTheNextDemand() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        try await fixture.until { !fixture.service.isWorking }
        let held = Gate()
        fixture.engine.nextGate = held
        let calls = fixture.engine.calls
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 300, reason: .playback)
        try await fixture.until { fixture.engine.calls == calls + 1 }

        let removal = Task { await fixture.service.removePreparedPassages() }
        try await Task.sleep(for: .milliseconds(100))
        held.open()
        await removal.value
        #expect(fixture.service.activeSessionKey == nil)
        #expect(fixture.service.queuedWindows.isEmpty)
        #expect(!fixture.service.store.hasStoredMapping(ebookStableId: fixture.ebook.stableId, audiobookStableId: fixture.audiobook.stableId))
        #expect(await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12) == .unprepared)
        #expect(await PassageAlignmentStore(root: fixture.service.store.root).mappingSet(for: fixture.builtIdentities[0]) == nil)
        #expect(fixture.service.status(ebook: fixture.ebook, audiobook: fixture.audiobook).coveredSeconds == 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.engine.calls == calls + 1)

        // Preparation resumes only when playback or a handoff asks for it again.
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        try await fixture.until { await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12).handoffMapping != nil }
        await fixture.session.retire()
    }

    @Test func demandArrivingDuringAStalledRemovalNeverSurvivesAndTheNextDemandAfterwardWorks() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        try await fixture.until { !fixture.service.isWorking }
        let held = Gate()
        fixture.engine.nextGate = held
        let calls = fixture.engine.calls
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 300, reason: .playback)
        try await fixture.until { fixture.engine.calls == calls + 1 }

        // The removal is stalled joining a window that ignores cancellation.
        let removal = Task { await fixture.service.removePreparedPassages() }
        try await Task.sleep(for: .milliseconds(100))
        let builds = fixture.builds
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        fixture.service.prepareWholeBook(ebook: fixture.ebook, audiobook: fixture.audiobook)
        #expect(await fixture.service.findReadingPosition(ebook: fixture.ebook, audiobook: fixture.audiobook, playhead: { 12 }, budget: .milliseconds(300)) == .unprepared)
        #expect(await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12) == .unprepared)
        let second = Task { await fixture.service.removePreparedPassages() }

        held.open()
        await removal.value
        await second.value
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.builds == builds)
        #expect(fixture.engine.calls == calls + 1)
        #expect(fixture.service.activeSessionKey == nil)
        #expect(fixture.service.queuedWindows.isEmpty)
        #expect(!fixture.service.store.hasStoredMapping(ebookStableId: fixture.ebook.stableId, audiobookStableId: fixture.audiobook.stableId))
        #expect(await PassageAlignmentStore(root: fixture.service.store.root).mappingSet(for: fixture.builtIdentities[0]) == nil)

        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        try await fixture.until { await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12).handoffMapping != nil }
        await fixture.session.retire()
    }

    @Test func aFailedSaveStopsPreparationUntilADeliberateRetryAndKeepsThePreviousMapping() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try await fixture.prepareNarratedSentence()
        try await fixture.until { !fixture.service.isWorking }
        let pair = fixture.service.store.root.appendingPathComponent("pairs/\(fixture.key)")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: pair.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pair.path) }
        fixture.service.storageRetryDelay = .milliseconds(800)
        fixture.service.store.windowsPerSave = 1
        let calls = fixture.engine.calls
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 300, reason: .playback)

        try await fixture.until { fixture.service.status(ebook: fixture.ebook, audiobook: fixture.audiobook).activity == .paused(.lowStorage) }
        let failedCalls = fixture.engine.calls
        #expect(failedCalls == calls + 1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.engine.calls == failedCalls)
        #expect(!fixture.service.isWorking)
        #expect(!fixture.service.queuedWindows.isEmpty)
        #expect(await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12).handoffMapping != nil)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pair.path)
        try await fixture.until { fixture.engine.calls > failedCalls }
        await fixture.session.retire()
    }

    @Test func lowFreeSpacePausesBeforeAnyInference() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.startup.open()
        fixture.service.minimumFreeBytes = .max
        fixture.service.storageRetryDelay = .milliseconds(500)
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        try await fixture.until { fixture.service.status(ebook: fixture.ebook, audiobook: fixture.audiobook).activity == .paused(.lowStorage) }
        #expect(fixture.engine.calls == 0)

        fixture.service.minimumFreeBytes = 0
        try await fixture.until { fixture.engine.calls > 0 }
        await fixture.session.retire()
    }

    @Test func aFailedStartupPausesWithItsReasonAndOnlyAnExplicitRequestRetries() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.startup.open()
        fixture.startupFailure = CocoaError(.fileReadCorruptFile)
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        try await fixture.until { fixture.service.status(ebook: fixture.ebook, audiobook: fixture.audiobook).activity == .paused(.preparationFailed) }

        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .lookAhead)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.builds == 1)

        fixture.startupFailure = nil
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 0, reason: .playback)
        try await fixture.until { fixture.service.activeSessionKey != nil }
        #expect(fixture.builds == 2)
        await fixture.session.retire()
    }

    @Test func theWindowOwningTheNarratedPositionIsAnalyzedFirst() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        fixture.startup.open()
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 300, reason: .playback)
        try await fixture.until { fixture.engine.analyzedWindows.count == 1 }
        let owner = CTCPassageWindow.owner(ofEnd: 300, in: CTCPassageWindow.grid(trackDuration: 600))
        #expect(owner != nil)
        #expect(fixture.engine.analyzedWindows.first == owner?.index)
        await fixture.session.retire()
    }

    @Test func failedOrUnmatchedWindowsAreAnalyzedAgainOnlyOnAnExplicitRetry() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // The session's text includes the narrated sentences; the engine recognizes none of them until the end.
        fixture.narrateSentence()
        let recognized = fixture.engine.matches
        fixture.engine.matches = []
        fixture.startup.open()
        fixture.engine.failure = CocoaError(.fileReadCorruptFile)
        let window = PassageWindowRef(trackIndex: 0, windowIndex: 0)
        let service = fixture.service!
        service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 12, reason: .playback, ahead: 10, behind: 0)
        try await fixture.until { service.status(ebook: fixture.ebook, audiobook: fixture.audiobook).failedWindows.contains(window) && !service.isWorking }

        // Neither a seek nor look-ahead re-spins a failed window.
        service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 12, reason: .playback, ahead: 10, behind: 0)
        service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 12, reason: .lookAhead, ahead: 10, behind: 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.engine.analyzedWindows == [0])

        // A retry that again finds no confident match leaves an attempted, unaccepted window.
        fixture.engine.failure = nil
        service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 12, reason: .playback, ahead: 10, behind: 0, retrying: true)
        #expect(service.status(ebook: fixture.ebook, audiobook: fixture.audiobook).isRetrying)
        try await fixture.until { fixture.engine.analyzedWindows == [0, 0] && !service.isWorking }
        let status = service.status(ebook: fixture.ebook, audiobook: fixture.audiobook)
        #expect(status.failedWindows.isEmpty && !status.isRetrying && status.analyzing == nil)
        let context = try #require(await service.readAlongContext(ebook: fixture.ebook, audiobook: fixture.audiobook))
        #expect(context.window(at: 12) == window)
        #expect(context.wasRejected(window))
        #expect(context.resolve(bookTime: 12) == .unprepared)

        service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 12, reason: .playback, ahead: 10, behind: 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.engine.analyzedWindows == [0, 0])

        fixture.engine.matches = recognized
        service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 12, reason: .playback, ahead: 10, behind: 0, retrying: true)
        try await fixture.until { await service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12).handoffMapping != nil }
        #expect(fixture.engine.analyzedWindows == [0, 0, 0])
        let accepted = try #require(await service.readAlongContext(ebook: fixture.ebook, audiobook: fixture.audiobook))
        #expect(!accepted.wasRejected(window))
        await fixture.session.retire()
    }

    @Test func onlyValidWordTimingsArePersistedAndMarkTheMappingAsWordTimed() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let narrated = PassageWordMatcher.printedWords(Fixture.narrated)
        fixture.engine.words[1] = narrated.enumerated().map {
            PassageWordTiming(location: $0.element.location, length: $0.element.length, start: 10 + Double($0.offset) * 0.4, end: 10.3 + Double($0.offset) * 0.4)
        }
        // Outside its sentence's observed span, so the whole set is dropped and the sentence stays usable.
        fixture.engine.words[0] = [PassageWordTiming(location: 0, length: 3, start: 1, end: 1.3)]
        try await fixture.prepareNarratedSentence()
        let context = try #require(await fixture.service.readAlongContext(ebook: fixture.ebook, audiobook: fixture.audiobook))
        let mappings = Dictionary(uniqueKeysWithValues: context.set.mappings.map { ($0.key.sentence, $0) })
        #expect(mappings[1]?.words == fixture.engine.words[1])
        #expect(mappings[1]?.granularity == .word)
        #expect(mappings[0]?.words == nil)
        #expect(mappings[0]?.granularity == .sentence)
        #expect(mappings[2]?.words == nil)
        await fixture.session.retire()
    }

    @Test func aSessionForAnotherEngineIsReplacedAndPreparedPassagesAreKept() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // This system selects QuartzNet, so a session running another engine is stale.
        fixture.sessionKind = .appleSpeech
        try await fixture.prepareNarratedSentence()
        #expect(fixture.builds == 1)
        fixture.sessionKind = .quartzNet
        fixture.service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 12, reason: .playback)
        try await fixture.until { fixture.builds == 2 && fixture.service.activeSessionKey != nil && fixture.engine.releases >= 1 }
        #expect(await fixture.service.audioResolution(ebook: fixture.ebook, audiobook: fixture.audiobook, bookTime: 12).handoffMapping != nil)
        await fixture.session.retire()
    }

    @Test func withdrawingARequestDuringStartupQueuesNothingAndLeavesOtherRequests() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let service = fixture.service!
        // Withdrawn while its session is still opening: the late session gets none of its windows.
        let stalled = service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 12, reason: .playback, ahead: 10, behind: 0)
        try await fixture.until { fixture.startupWaits == 1 }
        service.withdrawPreparation(stalled)
        fixture.startup.open()
        try await fixture.until { service.activeSessionKey != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(service.queuedWindows.isEmpty && fixture.engine.calls == 0)

        // Another request's windows survive withdrawing this one; the engine is held so both stay queued.
        let grid = CTCPassageWindow.grid(trackDuration: 600)
        let probeWindow = try #require(CTCPassageWindow.owner(ofEnd: 400, in: grid)).index
        let userWindow = try #require(CTCPassageWindow.owner(ofEnd: 200, in: grid)).index
        let first = service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 50, reason: .playback, ahead: 1, behind: 0)
        try await fixture.until { fixture.engine.calls == 1 }
        let probe = service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 400, reason: .lookAhead, ahead: 1, behind: 0)
        service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 200, reason: .lookAhead, ahead: 1, behind: 0)
        try await fixture.until { Set(service.queuedWindows.map(\.windowIndex)).isSuperset(of: [probeWindow, userWindow]) }
        service.withdrawPreparation(probe)
        #expect(service.queuedWindows.map(\.windowIndex).contains(userWindow))
        #expect(!service.queuedWindows.map(\.windowIndex).contains(probeWindow))
        // An earlier request's withdrawal is inert once its windows are analyzing or gone.
        service.withdrawPreparation(first)
        #expect(service.queuedWindows.map(\.windowIndex).contains(userWindow))
        await fixture.session.retire()
    }

    @Test func withdrawingWhileThePreparedPassagesLoadQueuesNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let service = fixture.service!
        fixture.startup.open()
        let load = Gate()
        final class Entered { var count = 0 }
        let entered = Entered()
        service.mappingLoadOverride = { [unowned service] identity in
            entered.count += 1
            await load.waitIgnoringCancellation()
            return await service.store.mappingSet(for: identity)
        }
        let request = service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 12, reason: .playback, ahead: 10, behind: 0)
        try await fixture.until { entered.count == 1 }
        service.withdrawPreparation(request)
        load.open()
        try await Task.sleep(for: .milliseconds(300))
        #expect(service.queuedWindows.isEmpty && fixture.engine.calls == 0)

        // A later request is unaffected.
        service.prepare(ebook: fixture.ebook, audiobook: fixture.audiobook, around: 12, reason: .playback, ahead: 10, behind: 0)
        try await fixture.until { fixture.engine.calls == 1 }
        await fixture.session.retire()
    }

    @Test func theListenAlongEngineChoiceIsSavedPerProfileAndSeparateFromConversion() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let service = fixture.service!
        let conversionMethod = fixture.session.defaults.string(forKey: "storyalign.method")
        #expect(service.liveEngine == nil)
        service.liveEngine = .quartzNet
        #expect(fixture.session.defaults.string(forKey: "passageAlignment.liveEngine") == "quartzNet")
        #expect(fixture.session.defaults.string(forKey: "storyalign.method") == conversionMethod)
        service.liveEngine = nil
        #expect(fixture.session.defaults.object(forKey: "passageAlignment.liveEngine") == nil)
        await fixture.session.retire()
    }

    @Test func quoteContextNeverCrossesAChapterDocument() {
        let sentences = [
            PassageSentence(key: .init(chapter: 0, sentence: 0), href: "OEBPS/c0.xhtml", text: "Last line of chapter zero.", chapterProgression: 0.9, totalProgression: 0.1),
            PassageSentence(key: .init(chapter: 1, sentence: 0), href: "OEBPS/c1.xhtml", text: "Chapter one opens here.", chapterProgression: 0, totalProgression: 0.2),
            PassageSentence(key: .init(chapter: 1, sentence: 1), href: "OEBPS/c1.xhtml", text: "Then it continues.", chapterProgression: 0.5, totalProgression: 0.3),
            PassageSentence(key: .init(chapter: 2, sentence: 0), href: "OEBPS/c2.xhtml", text: "Chapter two begins.", chapterProgression: 0, totalProgression: 0.4),
        ]
        let matches = [1, 2].map { PassageMatch(sentenceIndex: $0, start: Double($0), end: Double($0) + 0.5, score: -0.1) }
        let mappings = PassageAlignmentService.mappings(from: matches, sentences: sentences, track: 0, engine: "test", granularity: .sentence)
        #expect(mappings[0].before == "")
        #expect(mappings[0].after == "Then it continues.")
        #expect(mappings[1].before == "Chapter one opens here.")
        #expect(mappings[1].after == "")
    }

    /// A gate the controllable startup and engine wait on; cancellation releases a waiter with `CancellationError`.
    @MainActor
    final class Gate {
        private var isOpen = false
        private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        private var uncancellable: [CheckedContinuation<Void, Never>] = []

        func open() {
            isOpen = true
            let pending = waiters.values
            let ignoring = uncancellable
            waiters.removeAll()
            uncancellable.removeAll()
            pending.forEach { $0.resume() }
            ignoring.forEach { $0.resume() }
        }

        func waitIgnoringCancellation() async {
            guard !isOpen else { return }
            await withCheckedContinuation { uncancellable.append($0) }
        }

        func wait() async throws {
            guard !isOpen else { return }
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if isOpen { continuation.resume(); return }
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                    waiters[id] = continuation
                }
            } onCancel: {
                Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
            }
        }
    }

    @MainActor
    final class ScriptedEngine: PassageAlignmentEngine {
        let id = "scripted-engine"
        var granularity: PassageGranularity { .sentence }
        private(set) var calls = 0
        private(set) var releases = 0
        private(set) var analyzedWindows: [Int] = []
        var ignoresCancellation = false
        var failure: Error?
        var matches: [CTCPassageMatch] = []
        /// Observed word timings attached to a sentence's match, by sentence index.
        var words: [Int: [PassageWordTiming]] = [:]
        /// Holds only the next analysis, ignoring cancellation, so a test can act while one window is in flight.
        var nextGate: Gate?
        private let gate: Gate

        init(gate: Gate) {
            self.gate = gate
        }

        func analyze(window: CTCPassageWindow, previous: CTCPassageWindow?, track: PassageTrack) async throws -> [PassageMatch] {
            calls += 1
            analyzedWindows.append(window.index)
            if let failure { throw failure }
            if let held = nextGate {
                nextGate = nil
                await held.waitIgnoringCancellation()
            } else if ignoresCancellation {
                await gate.waitIgnoringCancellation()
            } else {
                try await gate.wait()
            }
            return matches.filter { window.owns(end: $0.end) }.map { match in
                var result = PassageMatch(match)
                result.words = words[match.sentenceIndex]
                return result
            }
        }

        func finishWork() {
            gate.open()
        }

        func pacing() async -> Duration { .milliseconds(10) }
        func release() async { releases += 1 }
    }

    @MainActor
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let startup = Gate()
        let engine: ScriptedEngine
        var startupIgnoresCancellation = false
        var startupFailure: Error?
        var sessionKind: PassageEngineKind = .quartzNet
        var sentences: [PassageSentence] = []
        private(set) var builds = 0
        private(set) var startupCancellations = 0
        /// Startups that finished identity work and are parked on the startup gate.
        private(set) var startupWaits = 0
        private(set) var builtIdentities: [PassageMediaIdentity] = []
        private(set) var session: ProfileSession!
        private(set) var service: PassageAlignmentService!
        private(set) var ebook: Book!
        private(set) var audiobook: Book!
        private(set) var audio: URL!
        private var domain = ""

        var key: String { PassageAlignmentService.pairKey(ebook: ebook, audiobook: audiobook) }

        init() async throws {
            engine = ScriptedEngine(gate: Gate())
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let profile = FamilyProfile(id: UUID().uuidString, name: "Passage service", role: .adult)
            domain = "PassageAlignmentServiceTests.\(profile.id)"
            let storage = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: root.appendingPathComponent("Caches"))
            guard let defaults = UserDefaults(suiteName: domain) else { throw CocoaError(.featureUnsupported) }
            session = try ProfileSession(profile: profile, storage: storage, defaults: defaults, libraryDatabase: Self.sharedDatabase())

            let pair = try makePair("service")
            ebook = pair.ebook
            audiobook = pair.audiobook
            audio = pair.audio

            let service = session.passageAlignment
            self.service = service
            service.modelDirectoryProvider = { [root] in root }
            let engine = engine
            service.sessionBuilderOverride = { [unowned self, unowned service] request in
                builds += 1
                if let startupFailure { throw startupFailure }
                let identity = try await service.identities.identity(
                    ebookStableId: request.ebook.stableId, audiobookStableId: request.audiobook.stableId,
                    epubURL: request.media.epub, audioURLs: request.media.audio
                )
                startupWaits += 1
                if startupIgnoresCancellation {
                    await startup.waitIgnoringCancellation()
                } else {
                    do {
                        try await startup.wait()
                    } catch {
                        startupCancellations += 1
                        throw error
                    }
                }
                builtIdentities.append(identity)
                let track = PassageTrack(index: 0, url: request.media.audio[0], digest: identity.trackRevisions[0], duration: 600, bookOffset: 0)
                return PassageAlignmentService.PreparationSession(
                    key: request.key, ebook: request.ebook, audiobook: request.audiobook, identity: identity, tracks: [track],
                    engine: engine, kind: sessionKind, sentences: sentences
                )
            }
        }

        func makePair(_ name: String) throws -> (ebook: Book, audiobook: Book, audio: URL) {
            let suffix = UUID().uuidString
            var audiobook = Book(id: "\(name)-audio-\(suffix)", title: name, source: .local, mediaType: .audiobook)
            audiobook.duration = 600
            var ebook = Book(id: "\(name)-ebook-\(suffix)", title: name, source: .local, mediaType: .ebook)
            let epub = session.storage.documentsDirectory.appendingPathComponent("Ebooks/local/\(name).epub")
            try FileManager.default.createDirectory(at: epub.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture epub \(name)".utf8).write(to: epub)
            ebook.ebookFileURL = epub
            ebook.linkedAudiobookStableId = audiobook.stableId
            let audioDirectory = session.localStorage.bookAudioDirectory(for: audiobook.downloadKey)
            try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            let audio = audioDirectory.appendingPathComponent("track.mp3")
            try Data(repeating: 7, count: 120_000).write(to: audio)
            return (ebook, audiobook, audio)
        }

        static let narratedHref = "OEBPS/c1.xhtml"
        static let narrated = "The lantern swung once and the harbor went quiet."

        /// A narrated passage the scripted engine recognizes; the middle sentence is spoken at 10–14 s. A window is
        /// accepted only with three matches. Startup still waits on its gate.
        func narrateSentence() {
            let texts = ["The tide had turned before dawn.", Self.narrated, "Nobody on the pier said a word."]
            sentences = texts.enumerated().map {
                PassageSentence(key: .init(chapter: 0, sentence: $0.offset), href: Self.narratedHref, text: $0.element, chapterProgression: 0.05 * Double($0.offset + 1), totalProgression: 0.05 * Double($0.offset + 1))
            }
            engine.matches = [(6.0, 9.5), (10.0, 14.0), (14.5, 18.0)].enumerated().map {
                CTCPassageMatch(sentenceIndex: $0.offset, start: $0.element.0, end: $0.element.1, score: -0.1)
            }
            engine.finishWork()
        }

        func prepareNarratedSentence() async throws {
            narrateSentence()
            startup.open()
            service.prepare(ebook: ebook, audiobook: audiobook, around: 0, reason: .playback)
            try await until { await self.service.audioResolution(ebook: self.ebook, audiobook: self.audiobook, bookTime: 12).handoffMapping != nil }
        }

        func findNarratedSentence(with service: PassageAlignmentService, budget: Duration = PassageAlignmentService.handoffBudget) async -> PassageTextResolution {
            await service.findListeningPosition(
                ebook: ebook, audiobook: audiobook, href: Self.narratedHref, quote: Self.narrated,
                chapterProgression: 0.1, estimatedBookTime: 0, budget: budget
            )
        }

        func until(_ condition: () async -> Bool, timeout: Duration = .seconds(5)) async throws {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while ContinuousClock.now < deadline {
                if await condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            Issue.record("Condition not reached within \(timeout)")
        }

        func remove() {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }

        // One long-lived library database for the suite: creating and deleting a store per test races the
        // iOS 17.0 runtime's asynchronous store setup.
        private static var database: BookStoreManager?

        private static func sharedDatabase() throws -> BookStoreManager {
            if let database { return database }
            let id = UUID().uuidString
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PassageAlignmentServiceTests-\(id)")
            let storage = ProfileStorageLocations(profileID: id,
                documentsDirectory: directory.appendingPathComponent("Documents"),
                applicationSupportDirectory: directory.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: directory.appendingPathComponent("Caches"))
            guard let defaults = UserDefaults(suiteName: "PassageAlignmentServiceTests.database.\(id)") else { throw CocoaError(.featureUnsupported) }
            let created = try BookStoreManager(storage: storage, defaults: defaults)
            database = created
            return created
        }
    }
}

extension PassageTextResolution {
    var isMatched: Bool {
        if case .matched = self { return true }
        return false
    }
}
