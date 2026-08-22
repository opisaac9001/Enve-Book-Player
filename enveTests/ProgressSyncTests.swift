import Foundation
import Testing

@testable import enve

@MainActor
struct ResolveConflictTests {
    @Test func neitherSideHasProgress() {
        let result = resolveProgressConflict(
            localPosition: 0,
            localDate: .distantPast,
            serverPosition: 0,
            serverDate: .distantPast
        )
        #expect(result == .none)
    }

    @Test func onlyServerHasProgress() {
        let result = resolveProgressConflict(
            localPosition: 0,
            localDate: .distantPast,
            serverPosition: 0.5,
            serverDate: Date()
        )
        #expect(result == .pull)
    }

    @Test func onlyLocalHasProgress() {
        let result = resolveProgressConflict(
            localPosition: 0.5,
            localDate: Date(),
            serverPosition: 0,
            serverDate: .distantPast
        )
        #expect(result == .push)
    }

    @Test func newerServerTimestampWins() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)
        let result = resolveProgressConflict(
            localPosition: 0.8,
            localDate: old,
            serverPosition: 0.3,
            serverDate: new
        )
        #expect(result == .pull)
    }

    @Test func newerLocalTimestampWins() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)
        let result = resolveProgressConflict(
            localPosition: 0.3,
            localDate: new,
            serverPosition: 0.8,
            serverDate: old
        )
        #expect(result == .push)
    }

    @Test func equalTimestampsFartherProgressWins() {
        let same = Date(timeIntervalSince1970: 1000)
        let result = resolveProgressConflict(
            localPosition: 0.3,
            localDate: same,
            serverPosition: 0.8,
            serverDate: same
        )
        #expect(result == .pull)

        let result2 = resolveProgressConflict(
            localPosition: 0.8,
            localDate: same,
            serverPosition: 0.3,
            serverDate: same
        )
        #expect(result2 == .push)
    }

    @Test func equalEverythingIsNone() {
        let same = Date(timeIntervalSince1970: 1000)
        let result = resolveProgressConflict(
            localPosition: 0.5,
            localDate: same,
            serverPosition: 0.5,
            serverDate: same
        )
        #expect(result == .none)
    }
}

@MainActor
struct ResolveConflictWithBackwardCheckTests {
    @Test func neitherSideHasProgress() {
        let result = resolveProgressConflictWithBackwardCheck(
            localPosition: 0,
            localDate: .distantPast,
            serverPosition: 0,
            serverDate: .distantPast
        )
        #expect(result == .none)
    }

    @Test func onlyServerHasProgress_pulls() {
        let result = resolveProgressConflictWithBackwardCheck(
            localPosition: 0,
            localDate: .distantPast,
            serverPosition: 0.5,
            serverDate: Date()
        )
        #expect(result == .pull)
    }

    @Test func onlyLocalHasProgress_pushes() {
        let result = resolveProgressConflictWithBackwardCheck(
            localPosition: 0.5,
            localDate: Date(),
            serverPosition: 0,
            serverDate: .distantPast
        )
        #expect(result == .push)
    }

    @Test func newerServerMovesForward_pulls() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)
        let result = resolveProgressConflictWithBackwardCheck(
            localPosition: 0.3,
            localDate: old,
            serverPosition: 0.8,
            serverDate: new
        )
        #expect(result == .pull)
    }

    @Test func newerServerMovesBackward_conflicts() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)
        let result = resolveProgressConflictWithBackwardCheck(
            localPosition: 0.8,
            localDate: old,
            serverPosition: 0.3,
            serverDate: new
        )
        #expect(result == .conflict)
    }

    @Test func newerLocalMovesForward_pushes() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)
        let result = resolveProgressConflictWithBackwardCheck(
            localPosition: 0.8,
            localDate: new,
            serverPosition: 0.3,
            serverDate: old
        )
        #expect(result == .push)
    }

    @Test func newerLocalMovesBackward_conflicts() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)
        let result = resolveProgressConflictWithBackwardCheck(
            localPosition: 0.3,
            localDate: new,
            serverPosition: 0.8,
            serverDate: old
        )
        #expect(result == .conflict)
    }

    @Test func equalTimestampsFartherProgressWins() {
        let same = Date(timeIntervalSince1970: 1000)
        let result = resolveProgressConflictWithBackwardCheck(
            localPosition: 0.3,
            localDate: same,
            serverPosition: 0.8,
            serverDate: same
        )
        #expect(result == .pull)
    }

    @Test func ebookPositionsWithinTolerance_none() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)

        let result = resolveProgressConflictWithBackwardCheck(
            localPosition: 0.500,
            localDate: old,
            serverPosition: 0.502,
            serverDate: new
        )
        #expect(result == .none)
    }

    @Test func audiobookPositionsWithinTolerance_none() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)

        let result = resolveProgressConflictWithBackwardCheck(
            localPosition: 27126,
            localDate: old,
            serverPosition: 27126,
            serverDate: new
        )
        #expect(result == .none)
    }

    @Test func audiobookPositionsWithinTwoSeconds_none() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)

        let result = resolveProgressConflictWithBackwardCheck(
            localPosition: 27126,
            localDate: old,
            serverPosition: 27127.5,
            serverDate: new
        )
        #expect(result == .none)
    }

    @Test func audiobookPositionsForwardPull() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)

        let result = resolveProgressConflictWithBackwardCheck(
            localPosition: 27126,
            localDate: old,
            serverPosition: 27186,
            serverDate: new
        )
        #expect(result == .pull)
    }

    @Test func audiobookPositionsBackwardConflict() {
        let old = Date(timeIntervalSince1970: 1000)
        let new = Date(timeIntervalSince1970: 2000)

        let result = resolveProgressConflictWithBackwardCheck(
            localPosition: 27126,
            localDate: old,
            serverPosition: 27066,
            serverDate: new
        )
        #expect(result == .conflict)
    }
}

@MainActor
struct PendingServerSyncTests {
    @Test func backoffDelayScalesExponentially() {
        var entry = PendingServerSync(
            stableId: "test",
            sourceRaw: "booklore",
            backendId: nil,
            serverItemId: "1",
            position: 100,
            duration: 500,
            updatedAt: Date().timeIntervalSince1970
        )
        #expect(entry.backoffDelay == 5)
        entry.retryCount = 1
        #expect(entry.backoffDelay == 10)
        entry.retryCount = 3
        #expect(entry.backoffDelay == 40)
        entry.retryCount = 10
        #expect(entry.backoffDelay == 900)
    }
}
