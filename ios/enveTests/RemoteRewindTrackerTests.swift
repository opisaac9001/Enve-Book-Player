import Foundation
import Testing

@testable import enve

@MainActor
struct RemoteRewindTrackerTests {
    private static let preciseLocator = #"{"href":"chapter3.xhtml","locations":{"cfi":"epubcfi(/6/4!/4/2/1:8)","totalProgression":0.32}}"#
    private static let percentageOnlyLocator = #"{"locations":{"totalProgression":0.32}}"#

    private func scope(
        source: String = "Living Room Server",
        connectionId: String = "connection-a",
        domain: ProgressSyncDomain = .ebook
    ) -> RemoteProgressScope {
        RemoteProgressScope(
            bookStableId: "book-1",
            domain: domain,
            connectionId: connectionId,
            source: source
        )
    }

    private func observation(
        _ progress: Double,
        at seconds: TimeInterval,
        locator: String? = RemoteRewindTrackerTests.preciseLocator,
        positionSeconds: TimeInterval? = nil
    ) -> RemoteProgressObservation {
        RemoteProgressObservation(
            progress: progress,
            positionSeconds: positionSeconds,
            locator: locator,
            observedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test func remoteAheadOfLocalIsNotARewind() {
        let tracker = RemoteRewindTracker()
        let verdict = tracker.assess(
            scope: scope(),
            observation: observation(0.8, at: 2000),
            localProgress: 0.6
        )
        #expect(verdict == .notRewind)
    }

    @Test func firstBackwardObservationIsUnconfirmed() {
        let tracker = RemoteRewindTracker()
        let verdict = tracker.assess(
            scope: scope(),
            observation: observation(0.3, at: 2000),
            localProgress: 0.6
        )
        #expect(verdict == .unconfirmed)
    }

    @Test func repeatedPollingOfTheSameObservationNeverConfirms() {
        let tracker = RemoteRewindTracker()
        let scope = scope()
        let stale = observation(0.3, at: 2000)
        for _ in 0..<5 {
            #expect(tracker.assess(scope: scope, observation: stale, localProgress: 0.6) == .unconfirmed)
        }
    }

    @Test func newerTimestampAloneDoesNotConfirm() {
        let tracker = RemoteRewindTracker()
        let scope = scope()
        _ = tracker.assess(scope: scope, observation: observation(0.3, at: 2000), localProgress: 0.6)
        let verdict = tracker.assess(
            scope: scope,
            observation: observation(0.3, at: 5000),
            localProgress: 0.6
        )
        #expect(verdict == .unconfirmed)
    }

    @Test func advancingObservationFromTheSameSourceConfirms() {
        let tracker = RemoteRewindTracker()
        let scope = scope()
        #expect(tracker.assess(scope: scope, observation: observation(0.3, at: 2000), localProgress: 0.6) == .unconfirmed)
        #expect(tracker.assess(scope: scope, observation: observation(0.35, at: 5000), localProgress: 0.6) == .confirmed)
    }

    @Test func confirmedVerdictIsStableWhenTheSameSnapshotIsAssessedTwice() {
        let tracker = RemoteRewindTracker()
        let scope = scope()
        _ = tracker.assess(scope: scope, observation: observation(0.3, at: 2000), localProgress: 0.6)
        let advance = observation(0.35, at: 5000)
        #expect(tracker.assess(scope: scope, observation: advance, localProgress: 0.6) == .confirmed)
        #expect(tracker.assess(scope: scope, observation: advance, localProgress: 0.6) == .confirmed)
    }

    @Test func advanceWithoutAPrecisePositionDoesNotConfirm() {
        let tracker = RemoteRewindTracker()
        let scope = scope()
        _ = tracker.assess(
            scope: scope,
            observation: observation(0.3, at: 2000, locator: Self.percentageOnlyLocator),
            localProgress: 0.6
        )
        let verdict = tracker.assess(
            scope: scope,
            observation: observation(0.35, at: 5000, locator: Self.percentageOnlyLocator),
            localProgress: 0.6
        )
        #expect(verdict == .unconfirmed)
    }

    @Test func audioPositionCountsAsAPrecisePosition() {
        let tracker = RemoteRewindTracker()
        let scope = scope(domain: .audiobook)
        _ = tracker.assess(
            scope: scope,
            observation: observation(0.3, at: 2000, locator: nil, positionSeconds: 3000),
            localProgress: 0.6
        )
        let verdict = tracker.assess(
            scope: scope,
            observation: observation(0.35, at: 5000, locator: nil, positionSeconds: 3500),
            localProgress: 0.6
        )
        #expect(verdict == .confirmed)
    }

    @Test func nearZeroResetDoesNotConfirmARewind() {
        let tracker = RemoteRewindTracker()
        let scope = scope()
        _ = tracker.assess(scope: scope, observation: observation(0.001, at: 2000), localProgress: 0.6)
        let verdict = tracker.assess(
            scope: scope,
            observation: observation(0.008, at: 5000),
            localProgress: 0.6
        )
        #expect(verdict == .unconfirmed)
    }

    @Test func advanceFromADifferentSourceDoesNotConfirm() {
        let tracker = RemoteRewindTracker()
        _ = tracker.assess(
            scope: scope(source: "Living Room Server"),
            observation: observation(0.3, at: 2000),
            localProgress: 0.6
        )
        let verdict = tracker.assess(
            scope: scope(source: "iCloud"),
            observation: observation(0.35, at: 5000),
            localProgress: 0.6
        )
        #expect(verdict == .unconfirmed)
    }

    @Test func advanceFromADifferentConnectionDoesNotConfirm() {
        let tracker = RemoteRewindTracker()
        _ = tracker.assess(
            scope: scope(connectionId: "connection-a"),
            observation: observation(0.3, at: 2000),
            localProgress: 0.6
        )
        let verdict = tracker.assess(
            scope: scope(connectionId: "connection-b"),
            observation: observation(0.35, at: 5000),
            localProgress: 0.6
        )
        #expect(verdict == .unconfirmed)
    }

    @Test func remoteReplayingOurOwnWriteIsAnEcho() {
        let tracker = RemoteRewindTracker()
        let scope = scope()
        tracker.recordOutboundWrite(
            key: scope.writeKey,
            progress: 0.3,
            positionSeconds: nil,
            locator: Self.preciseLocator,
            at: Date(timeIntervalSince1970: 1000)
        )
        let verdict = tracker.assess(
            scope: scope,
            observation: observation(0.3, at: 2000),
            localProgress: 0.6
        )
        #expect(verdict == .echo)
    }

    @Test func ourOwnWriteCannotConfirmAPendingRewind() {
        let tracker = RemoteRewindTracker()
        let scope = scope()
        #expect(tracker.assess(scope: scope, observation: observation(0.3, at: 2000), localProgress: 0.6) == .unconfirmed)

        tracker.recordOutboundWrite(
            key: scope.writeKey,
            progress: 0.6,
            positionSeconds: nil,
            locator: nil,
            at: Date(timeIntervalSince1970: 3000)
        )
        #expect(tracker.assess(scope: scope, observation: observation(0.6, at: 4000, locator: nil), localProgress: 0.65) == .echo)

        // The candidate survived our push, so the other device advancing still confirms the rewind.
        #expect(tracker.assess(scope: scope, observation: observation(0.35, at: 5000), localProgress: 0.65) == .confirmed)
    }

    @Test func keepingLocalSuppressesFurtherPromptsForThatSource() {
        let tracker = RemoteRewindTracker()
        let scope = scope()
        #expect(tracker.assess(scope: scope, observation: observation(0.3, at: 2000), localProgress: 0.6) == .unconfirmed)

        tracker.recordUserResolution(scope: scope, acceptedRemote: false)

        #expect(tracker.assess(scope: scope, observation: observation(0.35, at: 5000), localProgress: 0.6) == .dismissed)
        #expect(tracker.assess(scope: scope, observation: observation(0.4, at: 9000), localProgress: 0.6) == .dismissed)
    }

    @Test func dismissalClearsOnceTheSourceCatchesUp() {
        let tracker = RemoteRewindTracker()
        let scope = scope()
        _ = tracker.assess(scope: scope, observation: observation(0.3, at: 2000), localProgress: 0.6)
        tracker.recordUserResolution(scope: scope, acceptedRemote: false)
        #expect(tracker.assess(scope: scope, observation: observation(0.35, at: 5000), localProgress: 0.6) == .dismissed)

        #expect(tracker.assess(scope: scope, observation: observation(0.7, at: 9000), localProgress: 0.6) == .notRewind)
        #expect(tracker.assess(scope: scope, observation: observation(0.3, at: 12000), localProgress: 0.6) == .unconfirmed)
    }

    @Test func acceptingRemoteDropsThePendingCandidate() {
        let tracker = RemoteRewindTracker()
        let scope = scope()
        _ = tracker.assess(scope: scope, observation: observation(0.3, at: 2000), localProgress: 0.6)
        tracker.recordUserResolution(scope: scope, acceptedRemote: true)

        #expect(tracker.assess(scope: scope, observation: observation(0.35, at: 5000), localProgress: 0.6) == .unconfirmed)
    }

    @Test func observationWithoutATimestampNeverBecomesACandidate() {
        let tracker = RemoteRewindTracker()
        let scope = scope()
        let undated = RemoteProgressObservation(
            progress: 0.3,
            positionSeconds: nil,
            locator: Self.preciseLocator,
            observedAt: .distantPast
        )
        #expect(tracker.assess(scope: scope, observation: undated, localProgress: 0.6) == .unconfirmed)
        #expect(tracker.assess(scope: scope, observation: observation(0.35, at: 5000), localProgress: 0.6) == .unconfirmed)
    }
}
