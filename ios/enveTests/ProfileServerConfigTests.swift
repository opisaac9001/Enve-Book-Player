import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileServerConfigTests {
    @Test func smbAccountsAndPasswordsStayWithTheirProfile() throws {
        let ownerDomain = "com.enve.tests.profile.config.\(UUID().uuidString)"
        let childDomain = "com.enve.tests.profile.config.\(UUID().uuidString)"
        let ownerDefaults = try #require(UserDefaults(suiteName: ownerDomain))
        let childDefaults = try #require(UserDefaults(suiteName: childDomain))
        let owner = ServerConfigStore(profileID: FamilyProfile.ownerID, defaults: ownerDefaults)
        let childID = UUID().uuidString
        let child = ServerConfigStore(profileID: childID, defaults: childDefaults)
        let server = SMBServerConfiguration(
            displayName: "Owner", hostname: "test.invalid", shareName: "books", username: "owner"
        )
        defer {
            owner.deleteSMBPassword(for: server.id)
            child.deleteSMBPassword(for: server.id)
            ownerDefaults.removePersistentDomain(forName: ownerDomain)
            childDefaults.removePersistentDomain(forName: childDomain)
        }
        owner.saveSMBServers([server])
        owner.saveSMBPassword("owner-test-password", for: server.id)
        #expect(child.loadSMBServers().isEmpty)
        #expect(child.loadSMBPassword(for: server.id) == nil)
        var childServer = server
        childServer.displayName = "Child"
        childServer.username = "child"
        child.saveSMBServers([childServer])
        child.saveSMBPassword("child-test-password", for: server.id)

        let restored = ServerConfigStore(profileID: childID, defaults: childDefaults)
        #expect(restored.loadSMBServers() == [childServer])
        #expect(restored.loadSMBPassword(for: server.id) == "child-test-password")
        #expect(owner.loadSMBServers() == [server])
        #expect(owner.loadSMBPassword(for: server.id) == "owner-test-password")
        restored.deleteSMBPassword(for: server.id)
        #expect(owner.loadSMBPassword(for: server.id) == "owner-test-password")
        #expect(child.loadSMBPassword(for: server.id) == nil)
    }
}
