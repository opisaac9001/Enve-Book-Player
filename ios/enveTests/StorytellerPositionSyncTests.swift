import Foundation
import Testing

@testable import enve

@MainActor
struct StorytellerPositionSyncTests {
    @Test func pendingPositionTakesPrecedenceOverConfirmedServerPosition() {
        withLedger { ledger, key in
            let confirmed = position(key: key, progression: 0.2, timestamp: 1_000)
            let pending = position(key: key, progression: 0.6, timestamp: 2_000)

            ledger.mergeServer(confirmed)
            #expect(ledger.stage(pending))

            let authoritative = ledger.authoritative(for: key)
            #expect(authoritative?.position == pending)
            #expect(authoritative?.source == .pending)
        }
    }

    @Test func newerServerPositionClearsAnOlderPendingPosition() {
        withLedger { ledger, key in
            let pending = position(key: key, progression: 0.4, timestamp: 1_000)
            let server = position(key: key, progression: 0.8, timestamp: 2_000)

            #expect(ledger.stage(pending))
            ledger.mergeServer(server)

            #expect(ledger.pending(for: key) == nil)
            #expect(ledger.authoritative(for: key)?.position == server)
        }
    }

    @Test func staleLocalPositionCannotReplaceKnownServerPosition() {
        withLedger { ledger, key in
            let server = position(key: key, progression: 0.8, timestamp: 2_000)
            let stale = position(key: key, progression: 0.3, timestamp: 1_000)

            ledger.mergeServer(server)

            #expect(!ledger.stage(stale))
            #expect(ledger.authoritative(for: key)?.position == server)
        }
    }

    @Test func duplicateTimestampDoesNotReplaceTheQueuedLocator() {
        withLedger { ledger, key in
            let queued = position(key: key, progression: 0.4, timestamp: 1_000)
            let duplicate = position(key: key, progression: 0.7, timestamp: 1_000)

            #expect(ledger.stage(queued))
            #expect(!ledger.stage(duplicate))
            #expect(ledger.pending(for: key) == queued)
        }
    }

    @Test func acceptingAnOlderSendDoesNotRemoveANewerQueuedPosition() {
        withLedger { ledger, key in
            let first = position(key: key, progression: 0.3, timestamp: 1_000)
            let newer = position(key: key, progression: 0.7, timestamp: 2_000)

            #expect(ledger.stage(first))
            #expect(ledger.stage(newer))
            ledger.markAccepted(first)

            #expect(ledger.pending(for: key) == newer)
            #expect(ledger.authoritative(for: key)?.position == newer)
        }
    }

    @Test func pendingQueueSurvivesLedgerRecreation() {
        let suiteName = "StorytellerPositionSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = StorytellerPositionKey(providerId: UUID(), bookId: "book")
        let pending = position(key: key, progression: 0.5, timestamp: 1_000)

        #expect(StorytellerPositionLedger(defaults: defaults).stage(pending))

        let restored = StorytellerPositionLedger(defaults: defaults)
        #expect(restored.pending(for: key) == pending)
    }

    @Test func newerTimestampWinsEvenWhenPositionMovesBackward() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)

        #expect(
            resolveStorytellerPosition(
                localHasPosition: true,
                localDate: new,
                serverHasPosition: true,
                serverDate: old
            ) == .push
        )
        #expect(
            resolveStorytellerPosition(
                localHasPosition: true,
                localDate: old,
                serverHasPosition: true,
                serverDate: new
            ) == .pull
        )
    }

    @Test func equalTimestampsDoNotUseProgressAsATiebreaker() {
        let timestamp = Date(timeIntervalSince1970: 1_000)

        #expect(
            resolveStorytellerPosition(
                localHasPosition: true,
                localDate: timestamp,
                serverHasPosition: true,
                serverDate: timestamp
            ) == .none
        )
    }

    @Test func audioLocatorUsesTheSameLedgerAsTextLocators() {
        let suiteName = "StorytellerPositionSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = StorytellerPositionKey(providerId: UUID(), bookId: "book")
        let locator =
            "{\"href\":\"audio/chapter-11.m4b\",\"type\":\"audio/mp4\",\"locations\":{\"fragments\":[\"t=42.5\"],\"progression\":0.4,\"totalProgression\":0.71}}"
        let position = StorytellerSyncedPosition(
            key: key,
            locatorJSON: locator,
            timestampMilliseconds: 2_000
        )!
        let ledger = StorytellerPositionLedger(defaults: defaults)

        #expect(ledger.stage(position))
        #expect(ledger.authoritative(for: key)?.position.locatorJSON == locator)
        #expect(ledger.authoritative(for: key)?.position.progression == 0.71)
    }

    private func withLedger(
        _ body: (StorytellerPositionLedger, StorytellerPositionKey) -> Void
    ) {
        let suiteName = "StorytellerPositionSyncTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(
            StorytellerPositionLedger(defaults: defaults),
            StorytellerPositionKey(providerId: UUID(), bookId: "book")
        )
    }

    private func position(
        key: StorytellerPositionKey,
        progression: Double,
        timestamp: Int
    ) -> StorytellerSyncedPosition {
        StorytellerSyncedPosition(
            key: key,
            locatorJSON:
                "{\"href\":\"chapter.xhtml\",\"type\":\"application/xhtml+xml\",\"locations\":{\"totalProgression\":\(progression)}}",
            timestampMilliseconds: timestamp
        )!
    }
}
