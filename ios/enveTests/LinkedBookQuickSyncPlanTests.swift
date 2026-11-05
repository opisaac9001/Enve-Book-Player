import Foundation
import Testing

@testable import enve

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct LinkedBookQuickSyncPlanTests {
    private static func anchor(_ progress: Double) -> LinkedBookCalibrationAnchor {
        LinkedBookCalibrationAnchor(ebookProgress: progress, audioProgress: progress, quote: "line \(progress)", href: "c.xhtml", confidence: 0.9)
    }

    @Test func everyChapterMarkerIsCheckedWithoutACap() {
        let starts = (0..<120).map { TimeInterval($0) * 300 }
        let plan = LinkedBookQuickSyncPlan(chapterStarts: starts, duration: 36_000, sampleDuration: 24)
        #expect(plan.chapterCount == 120)
        #expect(Set(plan.points.flatMap(\.chapters)) == Set(0..<120))
        #expect(plan.points.allSatisfy { $0.time + 24 <= 36_000 })
        let first = plan.points.first { $0.chapters == [7] }
        #expect(first?.time == 7 * 300 + LinkedBookQuickSyncPlan.speechLead)
    }

    @Test func longChaptersGetInteriorPointsAndCloseMarkersShareOneCheck() {
        let plan = LinkedBookQuickSyncPlan(chapterStarts: [3_600, 0, 3_605, 9_000], duration: 9_900, sampleDuration: 24)
        #expect(plan.chapterCount == 4)
        #expect(Set(plan.points.flatMap(\.chapters)) == [0, 1, 2, 3])
        #expect(plan.points.contains { $0.chapters.count == 2 })
        let interior = plan.points.filter(\.chapters.isEmpty).map(\.time)
        #expect(interior.contains(600) && interior.contains(4_205) && interior.contains(9_600))
        #expect(plan.points.map(\.time) == plan.points.map(\.time).sorted())
    }

    @Test func withoutMarkersTheBookIsCheckedAtRegularPoints() {
        let plan = LinkedBookQuickSyncPlan(chapterStarts: [], duration: 3_000, sampleDuration: 24)
        #expect(plan.chapterCount == 0)
        #expect(plan.points.map(\.time) == [LinkedBookQuickSyncPlan.speechLead, 600, 1_200, 1_800, 2_400])
        let outside = LinkedBookQuickSyncPlan(chapterStarts: [-5, .nan, 5_000], duration: 3_000, sampleDuration: 24)
        #expect(outside.chapterCount == 0)
    }

    @Test func everyPointIsCheckedEvenAfterEnoughMatchesAndUnmatchedOnesAreCounted() async throws {
        let plan = LinkedBookQuickSyncPlan(chapterStarts: (0..<20).map { TimeInterval($0) * 100 }, duration: 2_000, sampleDuration: 24)
        var observed: [TimeInterval] = []
        var commits: [Int] = []
        var last = LinkedBookQuickSyncPass.Counts()
        let pass = LinkedBookQuickSyncPass(
            plan: plan,
            observe: { point in
                observed.append(point.time)
                return point.chapters.first.map { $0 % 4 == 3 ? nil : Self.anchor((point.time + 12) / 2_000) } ?? nil
            },
            ensureCurrent: {},
            liveWorkIsBusy: { false },
            waiting: { _ in },
            record: { _ in },
            progress: { last = $0 },
            commit: { commits.append($0.count) }
        )
        let outcomes = try await pass.run(cached: [:])
        #expect(observed == plan.points.map(\.time))
        #expect(outcomes.count == 20 && last.checked == 20 && last.chaptersChecked == 20 && last.chapterCount == 20)
        #expect(last.matched == 15 && last.unmatched == 5)
        #expect(commits == [6, 12])
    }

    @Test func successfulObservationsAreReusedAndMissesAreCheckedAgain() async throws {
        let plan = LinkedBookQuickSyncPlan(chapterStarts: [0, 600, 1_200, 1_800], duration: 2_400, sampleDuration: 24)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = LinkedBookQuickSyncObservations.Key(media: Self.media(), duration: 2_400, sampleDuration: 24, textTokens: 900)
        let first = LinkedBookQuickSyncObservations.Store(directory: directory, key: key)
        for point in plan.points.prefix(2) {
            first.save(.init(point: point, anchor: point.time < 100 ? nil : Self.anchor(point.time / 2_400)))
        }

        var observed: [TimeInterval] = []
        let reopened = LinkedBookQuickSyncObservations.Store(directory: directory, key: key)
        let pass = LinkedBookQuickSyncPass(
            plan: plan,
            observe: { observed.append($0.time); return Self.anchor($0.time / 2_400) },
            ensureCurrent: {}, liveWorkIsBusy: { false }, waiting: { _ in },
            record: { reopened.save($0) }, progress: { _ in }, commit: { _ in }
        )
        let outcomes = try await pass.run(cached: reopened.load())
        #expect(observed == [plan.points[0].time] + plan.points.dropFirst(2).map(\.time))
        #expect(outcomes.allSatisfy { $0.anchor != nil })
        #expect(LinkedBookQuickSyncObservations.Store(directory: directory, key: key).load().count == plan.points.count)
        let changed = LinkedBookQuickSyncObservations.Key(media: Self.media(), duration: 2_400, sampleDuration: 24, textTokens: 901)
        #expect(LinkedBookQuickSyncObservations.Store(directory: directory, key: changed).load().isEmpty)
        // A replaced EPUB or audio file of the same length and duration is a different identity.
        for media in [Self.media(reading: "other-epub"), Self.media(tracks: ["t1", "replaced"])] {
            let replaced = LinkedBookQuickSyncObservations.Key(media: media, duration: 2_400, sampleDuration: 24, textTokens: 900)
            #expect(LinkedBookQuickSyncObservations.Store(directory: directory, key: replaced).load().isEmpty)
        }
        // Another profile keeps its observations in its own directory.
        let otherProfile = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: otherProfile) }
        #expect(LinkedBookQuickSyncObservations.Store(directory: otherProfile, key: key).load().isEmpty)
    }

    @Test func cachedMissesAreRetriedAfterPassagesBecomeAvailable() async throws {
        let plan = LinkedBookQuickSyncPlan(chapterStarts: [0, 600, 1_200, 1_800], duration: 2_400, sampleDuration: 24)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = LinkedBookQuickSyncObservations.Key(media: Self.media(), duration: 2_400, sampleDuration: 24, textTokens: 900)
        let store = LinkedBookQuickSyncObservations.Store(directory: directory, key: key)
        var prepared = false
        var observed = 0
        let pass = LinkedBookQuickSyncPass(
            plan: plan,
            observe: { point in
                observed += 1
                return prepared ? Self.anchor(point.time / 2_400) : nil
            },
            ensureCurrent: {}, liveWorkIsBusy: { false }, waiting: { _ in },
            record: { store.save($0) }, progress: { _ in }, commit: { _ in }
        )
        let missing = try await pass.run(cached: [:])
        #expect(missing.count == plan.points.count && missing.allSatisfy { $0.anchor == nil })
        prepared = true
        let available = try await pass.run(cached: store.load())
        #expect(available.allSatisfy { $0.anchor != nil } && observed == plan.points.count * 2)
        #expect(try await pass.run(cached: store.load()) == available)
        #expect(observed == plan.points.count * 2)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect((object["outcomes"] as? [Any])?.count == plan.points.count)
    }

    @Test(arguments: [
        AudiobookTranscriptionError.speechAuthorizationDenied, .speechTranscriberUnavailable, .localeUnsupported, .assetUnavailable,
    ])
    func unavailableTranscriptionEndsThePassForCompatibilitySync(error: AudiobookTranscriptionError) async throws {
        let plan = LinkedBookQuickSyncPlan(chapterStarts: [0, 600], duration: 1_200, sampleDuration: 24)
        var attempts = 0
        var recorded = 0
        var commits = 0
        let pass = LinkedBookQuickSyncPass(
            plan: plan, observe: { _ in attempts += 1; throw error },
            ensureCurrent: {}, liveWorkIsBusy: { false }, waiting: { _ in },
            record: { _ in recorded += 1 }, progress: { _ in }, commit: { _ in commits += 1 }
        )
        #expect(try await pass.run(cached: [:]).isEmpty)
        #expect(attempts == 1 && recorded == 0 && commits == 0)
        let cancelled = LinkedBookQuickSyncPass(
            plan: plan, observe: { _ in throw CancellationError() },
            ensureCurrent: {}, liveWorkIsBusy: { false }, waiting: { _ in },
            record: { _ in Issue.record("Cancelled observation was saved") }, progress: { _ in },
            commit: { _ in Issue.record("Cancelled observation changed calibration") }
        )
        await #expect(throws: CancellationError.self) { try await cancelled.run(cached: [:]) }
    }

    @Test func transcriptionFailureKeepsAcceptedProvisionalCalibrationAndRollback() async throws {
        let plan = LinkedBookQuickSyncPlan(chapterStarts: (0..<16).map { TimeInterval($0) * 100 }, duration: 1_600, sampleDuration: 24)
        let original = (1...5).map { Self.anchor(Double($0) / 10) }
        var versions = LinkedBookCalibrationVersions()
        versions.install(original)
        let rollback = versions
        var observed = 0
        var recorded = 0
        let pass = LinkedBookQuickSyncPass(
            plan: plan,
            observe: { point in
                observed += 1
                if observed == 9 { throw AudiobookTranscriptionError.assetUnavailable }
                return Self.anchor((point.time + 12) / 1_600)
            },
            ensureCurrent: {}, liveWorkIsBusy: { false }, waiting: { _ in },
            record: { _ in recorded += 1 }, progress: { _ in },
            commit: { versions.install($0, keepingRollback: rollback) }
        )
        let outcomes = try await pass.run(cached: [:])
        #expect(outcomes.isEmpty && recorded == 8)
        let provisional = versions.accepted
        #expect(provisional?.count == 8 && versions.previous == original)
        #expect(!versions.install([], keepingRollback: rollback).isAccepted)
        #expect(versions.accepted == provisional && versions.previous == original)
    }

    @Test func observationFilesStayShortAndDistinctForLongOrLookalikeIds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let point = LinkedBookQuickSyncPlan.Point(time: 2, chapters: [0])
        let long = String(repeating: "local:/Very Long Folder/", count: 20)
        let pairs = [(long + "a", long + "b"), ("x/y", "z"), ("x-y", "z"), ("x:y", "z")]
        for (index, pair) in pairs.enumerated() {
            let key = LinkedBookQuickSyncObservations.Key(
                media: Self.media(ebook: pair.0, audio: pair.1), duration: 600, sampleDuration: 24, textTokens: 10
            )
            LinkedBookQuickSyncObservations.Store(directory: directory, key: key)
                .save(.init(point: point, anchor: Self.anchor(Double(index + 1) / 10)))
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(files.count == pairs.count && files.allSatisfy { $0.utf8.count <= 64 })
        for (index, pair) in pairs.enumerated() {
            let key = LinkedBookQuickSyncObservations.Key(
                media: Self.media(ebook: pair.0, audio: pair.1), duration: 600, sampleDuration: 24, textTokens: 10
            )
            let loaded = LinkedBookQuickSyncObservations.Store(directory: directory, key: key).load()
            #expect(loaded[point]?.anchor == Self.anchor(Double(index + 1) / 10))
        }
    }

    @Test func noPointIsCheckedWhileLiveReadAlongIsPreparing() async throws {
        let plan = LinkedBookQuickSyncPlan(chapterStarts: [0, 600], duration: 1_200, sampleDuration: 24)
        final class Live { var busyPolls = 3; var observedWhileBusy = false }
        let live = Live()
        var waits: [Bool] = []
        let pass = LinkedBookQuickSyncPass(
            plan: plan,
            observe: { point in
                if live.busyPolls > 0 { live.observedWhileBusy = true }
                return Self.anchor((point.time + 12) / 1_200)
            },
            ensureCurrent: {},
            liveWorkIsBusy: {
                guard live.busyPolls > 0 else { return false }
                live.busyPolls -= 1
                return true
            },
            waiting: { waits.append($0) },
            record: { _ in }, progress: { _ in }, commit: { _ in }
        )
        let outcomes = try await pass.run(cached: [:])
        #expect(outcomes.count == plan.points.count && !live.observedWhileBusy && waits == [true, false])

        final class Gate { var cancelled = false }
        let gate = Gate()
        let stalled = LinkedBookQuickSyncPass(
            plan: plan, observe: { _ in nil },
            ensureCurrent: { if gate.cancelled { throw CancellationError() } },
            liveWorkIsBusy: { true }, waiting: { _ in gate.cancelled = true },
            record: { _ in }, progress: { _ in }, commit: { _ in }
        )
        await #expect(throws: CancellationError.self) { try await stalled.run(cached: [:]) }
    }

    @Test func aSupersededRunStopsBeforeCheckingOrCommittingMore() async throws {
        let plan = LinkedBookQuickSyncPlan(chapterStarts: (0..<16).map { TimeInterval($0) * 100 }, duration: 1_600, sampleDuration: 24)
        final class Run { var current = true }
        let run = Run()
        var observed = 0
        var commits = 0
        let pass = LinkedBookQuickSyncPass(
            plan: plan,
            observe: { point in
                observed += 1
                if observed == 10 { run.current = false }
                return Self.anchor((point.time + 12) / 1_600)
            },
            ensureCurrent: { if !run.current { throw CancellationError() } },
            liveWorkIsBusy: { false }, waiting: { _ in },
            record: { _ in }, progress: { _ in }, commit: { _ in commits += 1 }
        )
        await #expect(throws: CancellationError.self) { try await pass.run(cached: [:]) }
        #expect(observed == 10 && commits == 1)
    }

    @Test func improvementsDuringARunKeepTheCalibrationFromBeforeItForRollback() {
        var versions = LinkedBookCalibrationVersions()
        let original = (1...5).map { Self.anchor(Double($0) / 10) }
        versions.install(original)
        let rollback = versions
        let better = (1...8).map { Self.anchor(Double($0) / 10) }
        let best = (1...9).map { Self.anchor(Double($0) / 10.5) } + [Self.anchor(0.95), Self.anchor(0.97)]
        #expect(versions.install(better, keepingRollback: rollback).isAccepted)
        #expect(versions.install(best, keepingRollback: rollback).isAccepted)
        #expect(versions.previous == original)
        #expect(versions.restorePrevious() && versions.accepted == original)
    }
    @Test func aRunsCalibrationLandsOnlyInItsOwnProfileWhileBothAreAlive() async throws {
        let fixture = try await LinkedBookQuickSyncIsolationTests.Fixture()
        defer { fixture.remove() }
        let ids = (ebook: fixture.ebook.stableId, audiobook: fixture.audiobook.stableId)
        let original = (1...5).map { Self.anchor(Double($0) / 10) }
        fixture.member.linkedProgress.installCalibration(ebookStableId: ids.ebook, audiobookStableId: ids.audiobook, anchors: original)
        let committer = LinkedBookQuickSyncCommitter(profile: fixture.member, ebook: fixture.ebook, audiobook: fixture.audiobook)
        let ownerBefore = fixture.owner.linkedProgress.calibration(ebookStableId: ids.ebook, audiobookStableId: ids.audiobook)
        try await Task.sleep(for: .milliseconds(20))

        #expect(committer.install((1...8).map { Self.anchor(Double($0) / 10) }).isAccepted)
        #expect(committer.install((1...9).map { Self.anchor(Double($0) / 10.5) } + [Self.anchor(0.95), Self.anchor(0.97)]).isAccepted)
        let member = fixture.member.linkedProgress.calibration(ebookStableId: ids.ebook, audiobookStableId: ids.audiobook)
        #expect(member.accepted?.count == 11 && member.previous == original)
        #expect(committer.summary?.anchorCount == 11)
        #expect(fixture.owner.linkedProgress.calibration(ebookStableId: ids.ebook, audiobookStableId: ids.audiobook) == ownerBefore)
        await fixture.retire()
    }
    @Test func cancellingAnOlderRunNeverStopsANewerOneForTheSamePair() async throws {
        let fixture = try await LinkedBookQuickSyncIsolationTests.Fixture()
        defer { fixture.remove() }
        let service = LinkedBookQuickSyncService.shared
        service.cancel()
        let older = try #require(service.start(ebook: fixture.ebook, audiobook: fixture.audiobook, profile: fixture.owner))
        service.cancel()
        let newer = try #require(service.start(ebook: fixture.ebook, audiobook: fixture.audiobook, profile: fixture.owner))
        #expect(older != newer && service.state?.runID == newer)
        service.cancel(run: older)
        #expect(service.isRunning(ebook: fixture.ebook, audiobook: fixture.audiobook) && service.state?.runID == newer)
        service.cancel(run: newer)
        #expect(service.state == nil && !service.isRunning(ebook: fixture.ebook, audiobook: fixture.audiobook))
        await fixture.retire()
    }

    private static func media(
        ebook: String = "e", audio: String = "a", reading: String = "epub-digest", tracks: [String] = ["t1", "t2"]
    ) -> PassageMediaIdentity {
        PassageMediaIdentity(ebookStableId: ebook, audiobookStableId: audio, readingRevision: reading, trackRevisions: tracks)
    }
}
