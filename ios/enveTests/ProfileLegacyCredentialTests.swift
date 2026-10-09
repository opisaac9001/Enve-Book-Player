import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileLegacyCredentialTests {
    @Test func tokensAndClientCertificatesStayInTheirCapturedProfile() throws {
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        let firstTokens = SecureTokenStorage(profileID: firstID)
        let secondTokens = SecureTokenStorage(profileID: secondID)
        let firstKeys = KeychainHelper(profileID: firstID)
        let secondKeys = KeychainHelper(profileID: secondID)
        defer {
            try? firstTokens.clearAll()
            try? secondTokens.clearAll()
            firstKeys.clearAll()
            secondKeys.clearAll()
        }
        let connectionID = UUID()
        let first = KeychainOPDSTokenStore(storage: firstTokens)
        let second = KeychainOPDSTokenStore(storage: secondTokens)
        first.setToken(OAuthToken(accessToken: "first", refreshToken: nil, expiresIn: nil,
                                 tokenType: "Bearer", scope: nil, issuedAt: Date()), forConnectionId: connectionID)
        #expect(second.token(forConnectionId: connectionID) == nil)
        second.setToken(OAuthToken(accessToken: "second", refreshToken: nil, expiresIn: nil,
                                  tokenType: "Bearer", scope: nil, issuedAt: Date()), forConnectionId: connectionID)
        #expect(first.token(forConnectionId: connectionID)?.accessToken == "first")
        #expect(second.token(forConnectionId: connectionID)?.accessToken == "second")
        let firstMTLS = MTLSManager(keychain: firstKeys)
        let secondMTLS = MTLSManager(keychain: secondKeys)
        firstMTLS.storePendingCertData(Data([1, 2, 3]))
        #expect(firstMTLS.hasPendingCertData)
        #expect(!secondMTLS.hasPendingCertData)
        secondMTLS.storePendingCertData(Data([4, 5, 6]))
        firstMTLS.clearPendingCert()
        #expect(!firstMTLS.hasPendingCertData)
        #expect(secondMTLS.hasPendingCertData)
    }

    @Test func legacyCredentialHelperCapturesProfileForReadsWritesAndClearAll() {
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        let first = KeychainHelper(profileID: firstID)
        let second = KeychainHelper(profileID: secondID)
        defer {
            first.clearAll()
            second.clearAll()
        }
        first.set("first-value", key: "same-account")
        #expect(second.get("same-account") == nil)
        second.set("second-value", key: "same-account")
        first.set("late-first-value", key: "same-account")
        #expect(KeychainHelper(profileID: firstID).get("same-account") == "late-first-value")
        #expect(KeychainHelper(profileID: secondID).get("same-account") == "second-value")
        first.clearAll()
        #expect(first.get("same-account") == nil)
        #expect(second.get("same-account") == "second-value")
    }
}
