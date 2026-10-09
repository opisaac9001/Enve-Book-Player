import Foundation
import Security
import Testing

@testable import enve

@MainActor
struct FamilyProfileStoreTests {
    @Test func restoresProfilesAndKeepsIdentityAfterRename() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = "com.enve.enve.tests.familyProfiles.\(UUID().uuidString)"
        defer { cleanUp(directory: directory, service: service) }
        let pinStore = AdultPINStore(service: service)
        let file = directory.appendingPathComponent("catalog.json")
        let store = try FamilyProfileStore(fileURL: file, pinStore: pinStore)
        let adult = try store.addAdult(name: "  Sam  ")
        #expect(throws: AdultPINError.notConfigured) { try store.addChild(name: "Alex") }
        try pinStore.configure("291746")
        let child = try store.addChild(name: "Alex")
        try store.rename(profileID: adult.id, name: "Samuel")

        let restored = try FamilyProfileStore(fileURL: file, pinStore: pinStore)
        #expect(restored.profiles.first?.id == FamilyProfile.ownerID)
        #expect(restored.profiles.first?.role == .adult)
        #expect(restored.profiles.first { $0.id == adult.id }?.name == "Samuel")
        #expect(restored.profiles.first { $0.id == child.id } == child)
        #expect(restored.profiles.count == 3)
    }

    @Test func invalidNamesDoNotChangeSavedProfiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = "com.enve.enve.tests.familyProfiles.\(UUID().uuidString)"
        defer { cleanUp(directory: directory, service: service) }
        let pinStore = AdultPINStore(service: service)
        let file = directory.appendingPathComponent("catalog.json")
        let store = try FamilyProfileStore(fileURL: file, pinStore: pinStore)
        let adult = try store.addAdult(name: "Sam")
        for name in ["", "  ", String(repeating: "a", count: 41)] {
            #expect(throws: FamilyProfileError.invalidName) { try store.addAdult(name: name) }
            #expect(throws: FamilyProfileError.invalidName) { try store.rename(profileID: adult.id, name: name) }
        }
        #expect(try FamilyProfileStore(fileURL: file, pinStore: pinStore).profiles == store.profiles)
    }

    @Test func malformedCatalogDoesNotFallBackToAnAdultProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = "com.enve.enve.tests.familyProfiles.\(UUID().uuidString)"
        defer { cleanUp(directory: directory, service: service) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("catalog.json")
        let child = FamilyProfile(id: "child", name: "Alex", role: .child)
        let owner = FamilyProfile(id: FamilyProfile.ownerID, name: "Adult", role: .adult)
        let invalidID = FamilyProfile(id: "../adult-default", name: "Alex", role: .child)
        for profiles in [[child], [owner, invalidID], [owner, owner]] {
            try JSONEncoder().encode(profiles).write(to: file)
            #expect(throws: FamilyProfileError.invalidCatalog) {
                try FamilyProfileStore(fileURL: file, pinStore: AdultPINStore(service: service))
            }
        }
    }

    @Test func failedWriteDoesNotPublishAnUnsavedProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let service = "com.enve.enve.tests.familyProfiles.\(UUID().uuidString)"
        defer { cleanUp(directory: directory, service: service) }
        try Data().write(to: directory)
        let store = try FamilyProfileStore(
            fileURL: directory.appendingPathComponent("catalog.json"),
            pinStore: AdultPINStore(service: service)
        )
        #expect(throws: (any Error).self) { try store.addAdult(name: "Sam") }
        #expect(store.profiles.count == 1)
    }

    private func cleanUp(directory: URL, service: String) {
        try? FileManager.default.removeItem(at: directory)
        SecItemDelete([
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
        ] as CFDictionary)
    }
}
