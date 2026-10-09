import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileCredentialTests {
    @Test func identicalConnectionIDsKeepCredentialsIndependent() {
        let owner = SharedKeychainStore.shared
        let child = SharedKeychainStore(profileID: UUID().uuidString)
        let connectionID = UUID().uuidString
        defer {
            owner.deleteAll(forConnectionId: connectionID)
            child.deleteAll(forConnectionId: connectionID)
            owner.deleteCustomHeaderValues(headerNames: ["X-Test"], forConnectionId: connectionID)
            child.deleteCustomHeaderValues(headerNames: ["X-Test"], forConnectionId: connectionID)
        }
        #expect(owner.setToken("owner-test-token", forConnectionId: connectionID))
        #expect(owner.setPassword("owner-test-password", forConnectionId: connectionID))
        #expect(owner.setCustomHeaderValue("owner-test-header", headerName: "X-Test", forConnectionId: connectionID))
        #expect(child.token(forConnectionId: connectionID) == nil)
        #expect(child.password(forConnectionId: connectionID) == nil)
        #expect(child.customHeaderValue(headerName: "X-Test", forConnectionId: connectionID) == nil)

        #expect(child.setToken("child-test-token", forConnectionId: connectionID))
        #expect(child.setPassword("child-test-password", forConnectionId: connectionID))
        #expect(child.setCustomHeaderValue("child-test-header", headerName: "X-Test", forConnectionId: connectionID))
        #expect(owner.token(forConnectionId: connectionID) == "owner-test-token")
        #expect(owner.password(forConnectionId: connectionID) == "owner-test-password")
        #expect(owner.customHeaderValue(headerName: "X-Test", forConnectionId: connectionID) == "owner-test-header")
        child.deleteAll(forConnectionId: connectionID)
        #expect(owner.token(forConnectionId: connectionID) == "owner-test-token")
        #expect(child.token(forConnectionId: connectionID) == nil)
    }

    @Test func profileCredentialsSurviveStoreRecreation() {
        let profileID = UUID().uuidString
        let connectionID = UUID().uuidString
        let store = SharedKeychainStore(profileID: profileID)
        defer { store.deleteAll(forConnectionId: connectionID) }
        #expect(store.setPlexHomeUserToken("test-home-token", forConnectionId: connectionID))
        #expect(store.setPlexOwnerToken("test-owner-token", forConnectionId: connectionID))

        let restored = SharedKeychainStore(profileID: profileID)
        #expect(restored.plexHomeUserToken(forConnectionId: connectionID) == "test-home-token")
        #expect(restored.plexOwnerToken(forConnectionId: connectionID) == "test-owner-token")
        #expect(SharedKeychainStore(profileID: UUID().uuidString).plexOwnerToken(forConnectionId: connectionID) == nil)
    }
}
