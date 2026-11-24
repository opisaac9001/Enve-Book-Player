import Foundation
import Testing

@testable import enve

@MainActor
struct CastMediaPlanTests {
    private func track(_ index: Int, start: TimeInterval, duration: TimeInterval, url: String? = nil) -> AudioTrackInfo {
        AudioTrackInfo(
            index: index,
            startOffset: start,
            duration: duration,
            contentUrl: url ?? "https://media.example.com/item/\(index).mp3?token=abc",
            mimeType: "audio/mpeg"
        )
    }

    @Test func resumeLandsInsideTheTrackThatContainsTheBookPosition() throws {
        let plan = try CastMediaPlan(
            tracks: [track(2, start: 2000, duration: 1000), track(0, start: 0, duration: 1000), track(1, start: 1000, duration: 1000)],
            resumeAt: 1500,
            streamingHeaders: ["Authorization": "Bearer abc"]
        )

        #expect(plan.entries.map(\.startOffset) == [0, 1000, 2000])
        #expect(plan.startIndex == 1)
        #expect(plan.startTime == 500)
        #expect(plan.duration == 3000)
    }

    @Test func receiverPositionsMapBackToTheBookTimeline() throws {
        let plan = try CastMediaPlan(
            tracks: [track(0, start: 0, duration: 600), track(1, start: 600, duration: 900)],
            resumeAt: 0,
            streamingHeaders: [:]
        )

        #expect(plan.globalPosition(trackIndex: 1, localPosition: 30) == 630)
        #expect(plan.globalPosition(trackIndex: 1, localPosition: 5000) == 1500)
        expectTarget(plan, global: 630, trackIndex: 1, local: 30)
        expectTarget(plan, global: 599, trackIndex: 0, local: 599)
        expectTarget(plan, global: 9999, trackIndex: 1, local: 900)
        expectTarget(plan, global: -10, trackIndex: 0, local: 0)
    }

    private func expectTarget(_ plan: CastMediaPlan, global: TimeInterval, trackIndex: Int, local: TimeInterval) {
        let target = plan.target(forGlobalPosition: global)
        #expect(target.trackIndex == trackIndex)
        #expect(target.localPosition == local)
    }

    @Test func resumePastTheEndStartsAtTheLastTrackEnd() throws {
        let plan = try CastMediaPlan(tracks: [track(0, start: 0, duration: 100)], resumeAt: 250, streamingHeaders: [:])

        #expect(plan.startIndex == 0)
        #expect(plan.startTime == 100)
    }

    @Test func startPositionIsOnTheBookTimelineNotTheTrack() throws {
        let plan = try CastMediaPlan(
            tracks: [track(0, start: 0, duration: 3600), track(1, start: 3600, duration: 3600)],
            resumeAt: 5400,
            streamingHeaders: [:]
        )

        #expect(plan.startTime == 1800)
        #expect(plan.startPosition == 5400)
    }

    @Test func nonFiniteOrNegativeTimelinesAreRejected() {
        for tracks in [
            [track(0, start: .nan, duration: 10)],
            [track(0, start: 0, duration: .infinity)],
            [track(0, start: -5, duration: 10)],
            [track(0, start: 0, duration: -1)],
        ] {
            #expect(throws: CastPlaybackError.invalidTimeline) {
                try CastMediaPlan(tracks: tracks, resumeAt: 0, streamingHeaders: [:])
            }
        }
    }

    @Test func multiTrackQueueWithUnknownInnerDurationIsRejected() {
        #expect(throws: CastPlaybackError.invalidTimeline) {
            try CastMediaPlan(
                tracks: [track(0, start: 0, duration: 0), track(1, start: 0, duration: 600)],
                resumeAt: 300,
                streamingHeaders: [:]
            )
        }
    }

    @Test func overlappingTrackOffsetsAreRejected() {
        #expect(throws: CastPlaybackError.invalidTimeline) {
            try CastMediaPlan(
                tracks: [track(0, start: 0, duration: 600), track(1, start: 300, duration: 600)],
                resumeAt: 0,
                streamingHeaders: [:]
            )
        }
    }

    @Test func singleTrackWithUnknownDurationIsStillCastable() throws {
        let plan = try CastMediaPlan(tracks: [track(0, start: 0, duration: 0)], resumeAt: 42, streamingHeaders: [:])

        #expect(plan.startPosition == 42)
    }

    @Test func newestLocalRecordWinsSoDeliberateRewindsSurvive() {
        let older = CastProgressSample(position: 5000, updatedAt: Date(timeIntervalSince1970: 100))
        let rewound = CastProgressSample(position: 1200, updatedAt: Date(timeIntervalSince1970: 200))
        let staleServer = CastProgressSample(position: 5000, updatedAt: Date(timeIntervalSince1970: 150))

        #expect(CastResumePolicy.resumePosition(local: [older, rewound], server: staleServer, tolerance: 5) == 1200)
    }

    @Test func newerServerProgressIsAdopted() {
        let local = CastProgressSample(position: 1200, updatedAt: Date(timeIntervalSince1970: 200))
        let server = CastProgressSample(position: 3000, updatedAt: Date(timeIntervalSince1970: 300))

        #expect(CastResumePolicy.resumePosition(local: [local], server: server, tolerance: 5) == 3000)
    }

    @Test func rewindToBeginningSurvivesStaleServerProgress() {
        let local = CastProgressSample(position: 0, updatedAt: Date(timeIntervalSince1970: 200))
        let server = CastProgressSample(position: 900, updatedAt: Date(timeIntervalSince1970: 100))
        #expect(CastResumePolicy.resumePosition(local: [local], server: server, tolerance: 5) == 0)
    }

    @Test func undatedServerPositionOnlyFillsAnEmptyLocalPosition() {
        let undated = CastProgressSample(position: 900, updatedAt: .distantPast)
        let local = CastProgressSample(position: 400, updatedAt: Date(timeIntervalSince1970: 50))

        #expect(CastResumePolicy.resumePosition(local: [], server: undated, tolerance: 5) == 900)
        #expect(CastResumePolicy.resumePosition(local: [local], server: undated, tolerance: 5) == 400)
    }

    @Test func serverWithinToleranceDoesNotJumpTheListener() {
        let local = CastProgressSample(position: 1200, updatedAt: Date(timeIntervalSince1970: 200))
        let server = CastProgressSample(position: 1203, updatedAt: Date(timeIntervalSince1970: 300))

        #expect(CastResumePolicy.resumePosition(local: [local], server: server, tolerance: 5) == 1200)
    }

    @Test func emptySessionIsRejected() {
        #expect(throws: CastPlaybackError.emptySession) {
            try CastMediaPlan(tracks: [], resumeAt: 0, streamingHeaders: [:])
        }
    }

    @Test func oneUnreachableTrackRejectsTheWholeQueue() {
        #expect(throws: CastPlaybackError.localMediaUnsupported) {
            try CastMediaPlan(
                tracks: [track(0, start: 0, duration: 10), track(1, start: 10, duration: 10, url: "file:///var/mobile/book.m4b")],
                resumeAt: 0,
                streamingHeaders: [:]
            )
        }
    }

    @Test func deviceOnlyURLsAreRejected() {
        for url in ["file:///var/mobile/book.m4b", "http://127.0.0.1:8080/stream.mp3", "http://localhost/stream.mp3", "content://book", "/relative/path.mp3"] {
            #expect(throws: CastPlaybackError.localMediaUnsupported) {
                try CastCompatibility.receiverURL(for: url, streamingHeaders: [:])
            }
        }
    }

    @Test func headerOnlyAuthenticationIsRejected() {
        #expect(throws: CastPlaybackError.headerAuthenticatedStream) {
            try CastCompatibility.receiverURL(
                for: "https://media.example.com/api/items/1/file/2",
                streamingHeaders: ["Authorization": "Bearer secret"]
            )
        }
    }

    @Test func credentialCarriedInTheURLIsAccepted() throws {
        let plex = try CastCompatibility.receiverURL(
            for: "https://media.example.com/library/parts/1/file.m4b?X-Plex-Token=secret",
            streamingHeaders: ["X-Plex-Token": "secret"]
        )
        let jellyfin = try CastCompatibility.receiverURL(
            for: "http://192.168.1.20:8096/Audio/1/stream?static=true&api_key=secret",
            streamingHeaders: ["Authorization": "MediaBrowser Token=secret", "X-Emby-Token": "secret"]
        )

        #expect(plex.host == "media.example.com")
        #expect(jellyfin.port == 8096)
    }

    @Test func customProxyHeadersCannotBeSentByTheReceiver() {
        #expect(throws: CastPlaybackError.headerAuthenticatedStream) {
            try CastCompatibility.receiverURL(
                for: "https://media.example.com/stream.mp3?token=secret",
                streamingHeaders: ["Authorization": "Bearer secret", "CF-Access-Client-Id": "proxy"]
            )
        }
    }

    @Test func emptyHeaderValuesDoNotRequireAURLCredential() throws {
        let url = try CastCompatibility.receiverURL(
            for: "https://media.example.com/stream.mp3",
            streamingHeaders: ["X-Emby-Token": ""]
        )

        #expect(url.path == "/stream.mp3")
    }

    @Test func embeddedUserInfoIsRejected() {
        #expect(throws: CastPlaybackError.headerAuthenticatedStream) {
            try CastCompatibility.receiverURL(for: "https://user:pass@media.example.com/stream.mp3", streamingHeaders: [:])
        }
    }

    @Test func privateHTTPSCertificatesCannotBeValidatedByTheReceiver() throws {
        for url in ["https://192.168.1.20/stream.mp3", "https://nas.local/stream.mp3", "https://box.tail1234.ts.net/stream.mp3"] {
            #expect(throws: CastPlaybackError.receiverCannotReachStream) {
                try CastCompatibility.receiverURL(for: url, streamingHeaders: [:])
            }
        }
        _ = try CastCompatibility.receiverURL(for: "http://nas.local:13378/stream.mp3", streamingHeaders: [:])
        _ = try CastCompatibility.receiverURL(for: "https://1-2-3-4.abc.plex.direct:32400/stream.mp3", streamingHeaders: [:])
    }

    @Test func errorMessagesNeverEchoTheStream() {
        let secret = "s3cr3t-token-value"
        do {
            _ = try CastCompatibility.receiverURL(
                for: "https://media.example.com/\(secret)/stream.mp3",
                streamingHeaders: ["Authorization": secret]
            )
            Issue.record("Expected header-only stream to be rejected")
        } catch {
            #expect(!error.localizedDescription.contains(secret))
            #expect(!error.localizedDescription.contains("media.example.com"))
        }
    }
}
