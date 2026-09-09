import Foundation
import Testing

@testable import enve

@MainActor
struct AuthenticationStorageTests {
    @Test func publicHostnamesDoNotInheritPrivateIPTrust() {
        for host in ["10.example.com", "192.168.example.com", "172.16.example.com", "100.64.example.com", "10.0.0.1.example.com", "10.999.0.1", "010.0.0.1", "10.0.0.01", "172.16.0", "192.168.0.1."] {
            #expect(!NetworkHostUtils.isLocalNetworkHost(host), "Unexpected local trust: \(host)")
        }
        for host in ["localhost", "127.0.0.1", "10.0.0.1", "192.168.255.255", "172.16.0.1", "172.31.255.255", "100.64.0.1", "100.127.255.255", "books.local"] {
            #expect(NetworkHostUtils.isLocalNetworkHost(host), "Missing local trust: \(host)")
        }
        for host in ["172.15.0.1", "172.32.0.1", "100.63.0.1", "100.128.0.1", "192.169.0.1", "8.8.8.8"] {
            #expect(!NetworkHostUtils.isLocalNetworkHost(host))
        }
    }

    @Test func persistedOAuthTokenRetainsExpiration() throws {
        let issuedAt = Date(timeIntervalSince1970: 1_600_000_000)
        let token = OAuthToken(accessToken: "test", refreshToken: "refresh", expiresIn: 3600, tokenType: "Bearer", scope: nil, issuedAt: issuedAt)
        let decoded = try JSONDecoder().decode(OAuthToken.self, from: JSONEncoder().encode(token))
        #expect(decoded.issuedAt == issuedAt)
        #expect(decoded.expiresAt == issuedAt.addingTimeInterval(3600))
        #expect(decoded.isExpired)
    }

    @Test func freshOAuthResponseUsesReceiptTime() throws {
        let before = Date()
        let token = try JSONDecoder().decode(OAuthToken.self, from: Data(#"{"access_token":"test","token_type":"Bearer","expires_in":3600}"#.utf8))
        #expect(token.issuedAt >= before)
        #expect(!token.isExpired)
    }

    @Test func tokenFormPreservesReservedCharacters() {
        let body = OAuthManager.formEncodedBody(["refresh_token": "a+b&c=d% e/é", "grant_type": "refresh_token"])
        #expect(String(decoding: body, as: UTF8.self) == "grant_type=refresh_token&refresh_token=a%2Bb%26c%3Dd%25%20e%2F%C3%A9")
    }

    @Test func keychainHelperReplacesExistingValue() {
        let key = "audit-test-\(UUID().uuidString)"
        defer { KeychainHelper.shared.delete(key) }
        KeychainHelper.shared.set("first", key: key)
        #expect(KeychainHelper.shared.get(key) == "first")
        KeychainHelper.shared.set("second", key: key)
        #expect(KeychainHelper.shared.get(key) == "second")
    }

    @Test func secureStorageReplacesExistingValue() throws {
        let service = "audit-test-\(UUID().uuidString)"
        defer { try? SecureTokenStorage.shared.deleteAPIKey(forService: service) }
        try SecureTokenStorage.shared.saveAPIKey("first", forService: service)
        #expect(try SecureTokenStorage.shared.loadAPIKey(forService: service) == "first")
        try SecureTokenStorage.shared.saveAPIKey("second", forService: service)
        #expect(try SecureTokenStorage.shared.loadAPIKey(forService: service) == "second")
    }
}
