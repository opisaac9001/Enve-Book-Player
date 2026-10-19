import Foundation
import Testing

@testable import enve

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ENVE_BOOKLORE_AUTH_FIXTURE_URL"] != nil))
struct BookloreAuthenticationRecoveryTests {
    @Test func futureRefreshTokenIsRetainedWithoutAnEarlyRequest() async throws {
        let endpoint = try await resetFixture(rejectRefresh: true)
        let provider = BookloreProvider(connection: ServerConnection(name: "Auth fixture", url: endpoint, type: .booklore))
        defer { provider.keychain.delete(provider.refreshTokenKeychainKey); provider.tierPreference.clear() }
        let payload = try JSONSerialization.data(withJSONObject: ["nbf": Date().addingTimeInterval(120).timeIntervalSince1970])
        let token = "e30." + payload.base64EncodedString().replacingOccurrences(of: "=", with: "") + ".fixture"
        provider.saveRefreshToken(token)
        #expect(!provider.shouldAttemptTokenRefresh())
        #expect(!(await provider.refreshStreamingTokenIfNeeded(force: true)))
        #expect(provider.refreshToken == token)
        #expect(provider.keychain.get(provider.refreshTokenKeychainKey) == token)
        #expect(try await refreshCount(endpoint: endpoint) == 0)
        await provider.retire()
    }

    @Test func rejectedRefreshFallsBackToPasswordAndReplacesStoredToken() async throws {
        let endpoint = try await resetFixture(rejectRefresh: true)
        let provider = BookloreProvider(connection: ServerConnection(name: "Auth fixture",
            url: endpoint, type: .booklore,
            username: "fixture-user", password: "fixture-password", token: "expired-access"))
        defer { provider.tierPreference.clear() }
        provider.saveRefreshToken("fixture-refresh")
        do {
            let request = try provider.makeRequest(path: "/api/v1/users/me")
            let (_, response) = try await provider.performAuthorizedRequest(request)
            #expect(response.statusCode == 200)
            #expect(try await refreshCount(endpoint: endpoint) == 1)
            #expect(provider.connection.token == "rotated-access")
            #expect(provider.refreshToken == "rotated-refresh")
            #expect(provider.keychain.get(provider.refreshTokenKeychainKey) == "rotated-refresh")
        } catch {
            provider.keychain.delete(provider.refreshTokenKeychainKey)
            await provider.retire()
            throw error
        }
        provider.keychain.delete(provider.refreshTokenKeychainKey)
        await provider.retire()
    }

    @Test func concurrentUnauthorizedRequestsRotateOnceAndReopenWithoutPassword() async throws {
        let endpoint = try await resetFixture(rejectRefresh: false, delayUnauthorized: true)
        let provider = BookloreProvider(connection: ServerConnection(name: "Auth fixture",
            url: endpoint, type: .booklore, token: "expired-access"))
        defer { provider.tierPreference.clear() }
        provider.saveRefreshToken("fixture-refresh")
        do {
            let request = try provider.makeRequest(path: "/api/v1/users/me")
            async let first = provider.performAuthorizedRequest(request)
            async let second = provider.performAuthorizedRequest(request)
            async let third = provider.performAuthorizedRequest(request)
            let responses = try await (first, second, third)
            #expect(responses.0.1.statusCode == 200)
            #expect(responses.1.1.statusCode == 200)
            #expect(responses.2.1.statusCode == 200)
            #expect(try await refreshCount(endpoint: endpoint) == 1)
            #expect(provider.connection.token == "rotated-access")
            #expect(provider.refreshToken == "rotated-refresh")

            var connection = provider.connection
            connection.token = nil
            let reopened = BookloreProvider(connection: connection)
            do {
                #expect(reopened.refreshToken == "rotated-refresh")
                #expect(try await reopened.validateConnection())
                #expect(try await refreshCount(endpoint: endpoint) == 2)
                await reopened.retire()
            } catch {
                await reopened.retire()
                throw error
            }
        } catch {
            provider.keychain.delete(provider.refreshTokenKeychainKey)
            await provider.retire()
            throw error
        }
        provider.keychain.delete(provider.refreshTokenKeychainKey)
        await provider.retire()
    }

    private func resetFixture(rejectRefresh: Bool, delayUnauthorized: Bool = false) async throws -> String {
        let endpoint = try #require(ProcessInfo.processInfo.environment["ENVE_BOOKLORE_AUTH_FIXTURE_URL"])
        let url = try #require(URL(string: endpoint + "/fixture/reset"))
        try #require(url.host == "127.0.0.1", "Authentication fixture must be local")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["rejectRefresh": rejectRefresh, "delayUnauthorized": delayUnauthorized])
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return endpoint
    }

    private func refreshCount(endpoint: String) async throws -> Int {
        let url = try #require(URL(string: endpoint + "/fixture/requests"))
        let (data, _) = try await URLSession.shared.data(from: url)
        let counts = try JSONDecoder().decode([String: Int].self, from: data)
        return try #require(counts["refresh"])
    }
}
