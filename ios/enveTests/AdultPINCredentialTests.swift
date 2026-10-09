import Foundation
import Testing

@testable import enve

@MainActor
struct AdultPINCredentialTests {
    @Test func verifiesAndResetsFailureCount() throws {
        var credential = try AdultPINCredential.create(pin: "123456")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(throws: AdultPINError.incorrect) { try credential.verify("000000", at: now) }
        #expect(credential.failedAttempts == 1)
        try credential.verify("123456", at: now)
        #expect(credential.failedAttempts == 0)
        #expect(credential.lockedUntil == nil)
    }

    @Test func lockoutPersistsAcrossEncoding() throws {
        var credential = try AdultPINCredential.create(pin: "1234")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<5 {
            #expect(throws: AdultPINError.incorrect) { try credential.verify("9999", at: now) }
        }
        let restored = try JSONDecoder().decode(AdultPINCredential.self, from: JSONEncoder().encode(credential))
        var retained = restored
        #expect(throws: AdultPINError.locked(until: now.addingTimeInterval(30))) {
            try retained.verify("1234", at: now.addingTimeInterval(29))
        }
        try retained.verify("1234", at: now.addingTimeInterval(30))
        #expect(retained.failedAttempts == 0)
    }

    @Test func rejectsInvalidPINs() {
        for pin in ["123", "1234567890123", "12a4", "１２３４"] {
            #expect(throws: AdultPINError.invalidFormat) { try AdultPINCredential.create(pin: pin) }
        }
    }
}
