import AVFoundation
import Foundation
import MediaPlayer
import Testing

@testable import enve

@MainActor
struct NowPlayingSessionLifecycleTests {
    @Test func clearingSessionLeavesItsPlayerAssociationIntact() {
        let coordinator = NowPlayingCoordinator()
        let target = SessionTarget()
        let player = AVPlayer()
        let session = MPNowPlayingSession(players: [player])
        session.automaticallyPublishesNowPlayingInfo = false

        coordinator.setNowPlayingSession(session, for: target)
        coordinator.clearNowPlayingSession(if: target)
        coordinator.clearNowPlayingSession(if: target)

        #expect(session.players.count == 1)
        #expect(session.players.first === player)
    }

    @Test func switchingPlayersLeavesTheRetiredSessionIntact() {
        let coordinator = NowPlayingCoordinator()
        let target = SessionTarget()
        let firstPlayer = AVPlayer()
        let secondPlayer = AVPlayer()
        let firstSession = MPNowPlayingSession(players: [firstPlayer])
        let secondSession = MPNowPlayingSession(players: [secondPlayer])
        firstSession.automaticallyPublishesNowPlayingInfo = false
        secondSession.automaticallyPublishesNowPlayingInfo = false

        coordinator.setNowPlayingSession(firstSession, for: target)
        coordinator.setNowPlayingSession(secondSession, for: target)

        #expect(firstSession.players.first === firstPlayer)
        #expect(secondSession.players.first === secondPlayer)
        coordinator.clearNowPlayingSession(if: target)
    }

    @Test func reinstallingTheSameSessionDoesNotDetachItsPlayer() {
        let coordinator = NowPlayingCoordinator()
        let target = SessionTarget()
        let player = AVPlayer()
        let session = MPNowPlayingSession(players: [player])
        session.automaticallyPublishesNowPlayingInfo = false

        coordinator.setNowPlayingSession(session, for: target)
        coordinator.setNowPlayingSession(session, for: target)

        #expect(session.players.first === player)
        coordinator.clearNowPlayingSession(if: target)
    }

    @Test func displacedOwnerCannotClearTheReplacementSession() async throws {
        let coordinator = NowPlayingCoordinator()
        let firstTarget = SessionTarget()
        let secondTarget = SessionTarget()
        let firstPlayer = AVPlayer()
        let secondPlayer = AVPlayer()
        weak var firstSession: MPNowPlayingSession?
        weak var secondSession: MPNowPlayingSession?

        autoreleasepool {
            let session = MPNowPlayingSession(players: [firstPlayer])
            session.automaticallyPublishesNowPlayingInfo = false
            firstSession = session
            coordinator.setNowPlayingSession(session, for: firstTarget)
        }
        autoreleasepool {
            let session = MPNowPlayingSession(players: [secondPlayer])
            session.automaticallyPublishesNowPlayingInfo = false
            secondSession = session
            coordinator.setNowPlayingSession(session, for: secondTarget)
            coordinator.clearNowPlayingSession(if: firstTarget)
        }

        try await waitForRelease { firstSession }
        #expect(firstSession == nil)
        #expect(secondSession != nil)
        autoreleasepool { coordinator.clearNowPlayingSession(if: secondTarget) }
        try await waitForRelease { secondSession }
        #expect(secondSession == nil)
    }

    @Test func displacedOwnerCanReclaimItsRetainedSession() async throws {
        let coordinator = NowPlayingCoordinator()
        let firstTarget = SessionTarget()
        let secondTarget = SessionTarget()
        let firstPlayer = AVPlayer()
        let secondPlayer = AVPlayer()
        let firstSession = MPNowPlayingSession(players: [firstPlayer])
        firstSession.automaticallyPublishesNowPlayingInfo = false
        weak var secondSession: MPNowPlayingSession?

        coordinator.setNowPlayingSession(firstSession, for: firstTarget)
        autoreleasepool {
            let session = MPNowPlayingSession(players: [secondPlayer])
            session.automaticallyPublishesNowPlayingInfo = false
            secondSession = session
            coordinator.setNowPlayingSession(session, for: secondTarget)
            coordinator.setNowPlayingSession(firstSession, for: firstTarget)
        }
        coordinator.clearNowPlayingSession(if: secondTarget)
        coordinator.updateNowPlaying(NowPlayingInfo(title: "Resumed episode"))

        try await waitForRelease { secondSession }
        #expect(secondSession == nil)
        #expect(firstSession.players.first === firstPlayer)
        #expect(firstSession.nowPlayingInfoCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Resumed episode")
        coordinator.clearNowPlayingSession(if: firstTarget)
    }

    @Test func repeatedPlayerReplacementReleasesEveryRetiredSession() async throws {
        let coordinator = NowPlayingCoordinator()
        let target = SessionTarget()

        for _ in 0..<25 {
            let player = AVPlayer()
            weak var retiredSession: MPNowPlayingSession?
            autoreleasepool {
                let session = MPNowPlayingSession(players: [player])
                session.automaticallyPublishesNowPlayingInfo = false
                retiredSession = session
                coordinator.setNowPlayingSession(session, for: target)
            }

            #expect(retiredSession != nil)
            autoreleasepool { coordinator.clearNowPlayingSession(if: target) }
            try await waitForRelease { retiredSession }
            #expect(retiredSession == nil)
        }
    }

    private func waitForRelease(_ session: () -> MPNowPlayingSession?) async throws {
        // MediaPlayer can retain sessions until queued registration work completes.
        for _ in 0..<100 {
            if autoreleasepool(invoking: { session() == nil }) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class SessionTarget: RemoteCommandTarget {
    func remotePlay() {}
    func remotePause() {}
    func remoteToggle() {}
    func remoteNext() {}
    func remotePrevious() {}
    func remoteSkipForward(by seconds: TimeInterval?) {}
    func remoteSkipBackward(by seconds: TimeInterval?) {}
    func remoteSeek(to positionTime: TimeInterval) {}
}
