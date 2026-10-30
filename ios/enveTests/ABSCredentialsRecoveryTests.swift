import Foundation
import Testing

@testable import enve

@Suite(.timeLimit(.minutes(1))) @MainActor
struct ABSCredentialsRecoveryTests {
    @Test func unauthorizedRequestJoinsRefreshAlreadyInProgress() async throws {
        let provider = RefreshProvider()
        let credentials = ABSCredentialsActor(provider: provider)
        let first = Task { try await credentials.freshCredentials }
        await provider.waitForRefresh()
        let (secondStarted, signal) = AsyncStream<Void>.makeStream()
        let second = Task {
            signal.finish()
            return try await credentials.forceRefresh()
        }
        for await _ in secondStarted {}
        provider.releaseRefresh()
        let results = try await (first.value, second.value)
        #expect(results.0.accessToken == results.1.accessToken)
        #expect(provider.refreshCount == 1)
        await credentials.retire()
    }

    @Test func retirementCancelsRefreshWithoutPublishingCredentials() async throws {
        let provider = RefreshProvider()
        let credentials = ABSCredentialsActor(provider: provider)
        let pending = Task { try await credentials.freshCredentials }
        await provider.waitForRefresh()
        await credentials.retire()
        do {
            _ = try await pending.value
            Issue.record("Retired refresh returned credentials")
        } catch is CancellationError {}
        #expect(provider.publishedToken == nil)
        do {
            _ = try await credentials.forceRefresh()
            Issue.record("Retired provider started another refresh")
        } catch is CancellationError {}
        #expect(provider.refreshCount == 1)
    }

    @Test func lateUnauthorizedResponseUsesAlreadyRotatedToken() async throws {
        let provider = RefreshProvider()
        let credentials = ABSCredentialsActor(provider: provider)
        let rejected = provider.tokenSnapshot.token
        provider.releaseRefresh()
        let refreshed = try await credentials.freshCredentials
        let retry = try await credentials.forceRefresh(rejectedToken: rejected)
        #expect(retry.accessToken == refreshed.accessToken)
        #expect(provider.refreshCount == 1)
        await credentials.retire()
    }

    @Test func cancelledCallerCannotStartRefresh() async throws {
        let provider = RefreshProvider()
        let credentials = ABSCredentialsActor(provider: provider)
        let pending = Task { try await credentials.forceRefresh() }
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("Cancelled caller received credentials")
        } catch is CancellationError {}
        #expect(provider.refreshCount == 0)
        await credentials.retire()
    }
}

@MainActor
private final class RefreshProvider: AudiobookshelfProvider, @unchecked Sendable {
    private(set) var refreshCount = 0
    private(set) var publishedToken: String?
    private let refreshStarted = AsyncStream<Void>.makeStream()
    private let refreshReleased = AsyncStream<Void>.makeStream()

    init() {
        super.init(connection: ServerConnection(name: "Recovery fixture", url: "https://example.test", type: .audiobookshelf))
    }

    override var tokenSnapshot: ABSTokenSnapshot {
        ABSTokenSnapshot(token: publishedToken ?? "e30.eyJleHAiOjEsInR5cGUiOiJhY2Nlc3MifQ.fixture", refreshToken: "fixture-refresh")
    }

    func waitForRefresh() async {
        for await _ in refreshStarted.stream {}
    }

    func releaseRefresh() {
        refreshReleased.continuation.finish()
    }

    override func performTokenRefresh() async throws -> ABSCredentials {
        refreshCount += 1
        refreshStarted.continuation.finish()
        for await _ in refreshReleased.stream {}
        try Task.checkCancellation()
        let token = "rotated-fixture"
        publishedToken = token
        return .legacy(token: token)
    }
}
