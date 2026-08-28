import Foundation
import Testing

@testable import enve

struct LibraryHealthPolicyTests {
    @Test func attentionConditionsTakePriority() {
        #expect(
            LibraryHealthPolicy.level(
                sourceHealth: [.ready, .needsSignIn],
                pendingSyncCount: 0,
                failedDownloadCount: 0,
                orphanDownloadCount: 0,
                availableBytes: 10_000_000_000,
                recentSystemIncidentCount: 0
            ) == .attention
        )
        #expect(
            LibraryHealthPolicy.level(
                sourceHealth: [.ready],
                pendingSyncCount: 0,
                failedDownloadCount: 1,
                orphanDownloadCount: 0,
                availableBytes: 10_000_000_000,
                recentSystemIncidentCount: 0
            ) == .attention
        )
    }

    @Test func noticeCoversPendingWorkAndLowStorage() {
        #expect(
            LibraryHealthPolicy.level(
                sourceHealth: [.ready],
                pendingSyncCount: 2,
                failedDownloadCount: 0,
                orphanDownloadCount: 0,
                availableBytes: 10_000_000_000,
                recentSystemIncidentCount: 0
            ) == .notice
        )
        #expect(
            LibraryHealthPolicy.level(
                sourceHealth: [.ready],
                pendingSyncCount: 0,
                failedDownloadCount: 0,
                orphanDownloadCount: 0,
                availableBytes: 500_000_000,
                recentSystemIncidentCount: 0
            ) == .notice
        )
    }

    @Test func readyRequiresConnectedSourcesAndNoOutstandingIssues() {
        #expect(
            LibraryHealthPolicy.level(
                sourceHealth: [.ready],
                pendingSyncCount: 0,
                failedDownloadCount: 0,
                orphanDownloadCount: 0,
                availableBytes: 10_000_000_000,
                recentSystemIncidentCount: 0
            ) == .ready
        )
    }
}
