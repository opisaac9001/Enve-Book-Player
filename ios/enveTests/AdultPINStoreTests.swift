import Foundation
import Security
import Testing

@testable import enve

@MainActor
struct AdultPINStoreTests {
    @Test func pinChangeSurvivesStoreRecreation() throws {
        let service = "com.enve.enve.tests.familyProfiles.\(UUID().uuidString)"
        defer { removeCredential(service: service) }
        let store = AdultPINStore(service: service)
        #expect(try !store.isConfigured())
        try store.configure("291746")
        #expect(try AdultPINStore(service: service).isConfigured())

        #expect(throws: AdultPINError.incorrect) {
            try store.change("638152", currentPIN: "000000")
        }
        try AdultPINStore(service: service).verify("291746")
        try store.change("638152", currentPIN: "291746")

        let restored = AdultPINStore(service: service)
        #expect(throws: AdultPINError.incorrect) { try restored.verify("291746") }
        try restored.verify("638152")
    }

    @Test func lockoutSurvivesStoreRecreation() throws {
        let service = "com.enve.enve.tests.familyProfiles.\(UUID().uuidString)"
        defer { removeCredential(service: service) }
        let store = AdultPINStore(service: service)
        try store.configure("291746")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<5 {
            #expect(throws: AdultPINError.incorrect) { try store.verify("000000", at: now) }
        }
        let restored = AdultPINStore(service: service)
        #expect(throws: AdultPINError.locked(until: now.addingTimeInterval(30))) {
            try restored.verify("291746", at: now.addingTimeInterval(29))
        }
        try restored.verify("291746", at: now.addingTimeInterval(30))
    }

    @Test func invalidReplacementPreservesExistingCredential() throws {
        let service = "com.enve.enve.tests.familyProfiles.\(UUID().uuidString)"
        defer { removeCredential(service: service) }
        let store = AdultPINStore(service: service)
        try store.configure("291746")
        #expect(throws: AdultPINError.invalidFormat) {
            try store.change("bad", currentPIN: "291746")
        }
        try AdultPINStore(service: service).verify("291746")
    }

    private func removeCredential(service: String) {
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ] as CFDictionary)
    }
}
