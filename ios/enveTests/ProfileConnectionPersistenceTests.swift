import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileConnectionPersistenceTests {
    @Test func identicalConnectionIDsPersistAndReloadWithinTheirProfile() async throws {
        let firstID = UUID().uuidString
        let secondID = UUID().uuidString
        let connectionID = UUID()
        let firstDefaults = try #require(UserDefaults(suiteName: firstID))
        let secondDefaults = try #require(UserDefaults(suiteName: secondID))
        let firstKeychain = SharedKeychainStore(profileID: firstID)
        let secondKeychain = SharedKeychainStore(profileID: secondID)
        defer {
            firstDefaults.removePersistentDomain(forName: firstID)
            secondDefaults.removePersistentDomain(forName: secondID)
            cleanUp(keychain: firstKeychain, connectionID: connectionID)
            cleanUp(keychain: secondKeychain, connectionID: connectionID)
        }
        let firstConfig = ServerConfigStore(profileID: firstID, defaults: firstDefaults)
        let secondConfig = ServerConfigStore(profileID: secondID, defaults: secondDefaults)
        let first = ProviderConnectionStore(
            profileID: firstID, defaults: firstDefaults, keychain: firstKeychain,
            serverConfig: firstConfig, providerFactory: { _ in nil }
        )
        let second = ProviderConnectionStore(
            profileID: secondID, defaults: secondDefaults, keychain: secondKeychain,
            serverConfig: secondConfig, providerFactory: { _ in nil }
        )
        first.connections = [connection(id: connectionID, name: "First", secret: "first-secret")]
        second.connections = [connection(id: connectionID, name: "Second", secret: "second-secret")]
        await Task.yield()

        let firstData = try #require(firstDefaults.data(forKey: "enve_server_connections"))
        let secondData = try #require(secondDefaults.data(forKey: "enve_server_connections"))
        for data in [firstData, secondData] {
            let json = try #require(String(data: data, encoding: .utf8))
            #expect(!json.contains("first-secret"))
            #expect(!json.contains("second-secret"))
            let objects = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            let object = try #require(objects.first)
            #expect(object["token"] == nil)
            #expect(object["password"] == nil)
            #expect(object["plexHomeUserToken"] == nil)
            #expect(object["plexOwnerToken"] == nil)
        }
        let restoredFirst = ProviderConnectionStore(
            profileID: firstID, defaults: firstDefaults, keychain: firstKeychain,
            serverConfig: firstConfig, providerFactory: { _ in nil }
        )
        let restoredSecond = ProviderConnectionStore(
            profileID: secondID, defaults: secondDefaults, keychain: secondKeychain,
            serverConfig: secondConfig, providerFactory: { _ in nil }
        )
        #expect(restoredFirst.connections.first?.token == "first-secret")
        #expect(restoredSecond.connections.first?.token == "second-secret")
        #expect(restoredFirst.connections.first?.customHeaders?["X-API-Key"] == "first-secret")
        #expect(restoredSecond.connections.first?.customHeaders?["X-API-Key"] == "second-secret")
        #expect(restoredFirst.connections.first?.plexOwnerToken == "first-secret")
        #expect(restoredSecond.connections.first?.plexHomeUserToken == "second-secret")

        first.connections = [connection(id: connectionID, name: "First updated", secret: "late-first-secret")]
        await Task.yield()
        second.refresh()
        first.refresh()
        #expect(first.connections.first?.token == "late-first-secret")
        #expect(second.connections.first?.token == "second-secret")
        #expect(second.connections.first?.name == "Second")
        #expect(firstKeychain.token(forConnectionId: connectionID.uuidString) == "late-first-secret")
        #expect(secondKeychain.token(forConnectionId: connectionID.uuidString) == "second-secret")
    }

    @Test func explicitCodableKeychainsDoNotUseTheOwnerFallback() throws {
        let profileID = UUID().uuidString
        let connectionID = UUID()
        let keychain = SharedKeychainStore(profileID: profileID)
        defer { cleanUp(keychain: keychain, connectionID: connectionID) }
        let encoder = JSONEncoder()
        encoder.userInfo[ServerConnection.keychainUserInfoKey] = keychain
        let data = try encoder.encode(connection(id: connectionID, name: "Scoped", secret: "scoped-secret"))
        #expect(keychain.token(forConnectionId: connectionID.uuidString) == "scoped-secret")
        #expect(SharedKeychainStore.shared.token(forConnectionId: connectionID.uuidString) == nil)
        let decoder = JSONDecoder()
        decoder.userInfo[ServerConnection.keychainUserInfoKey] = SharedKeychainStore(profileID: profileID)
        let restored = try decoder.decode(ServerConnection.self, from: data)
        #expect(restored.token == "scoped-secret")
        #expect(restored.password == "scoped-secret")
        #expect(restored.plexOwnerToken == "scoped-secret")
        #expect(restored.plexHomeUserToken == "scoped-secret")
    }

    @Test func onlyOwnerImportsAndResolvesLegacyBackends() throws {
        let fixtureID = UUID().uuidString
        let childID = UUID().uuidString
        let backendID = UUID()
        let fixtureDefaults = try #require(UserDefaults(suiteName: fixtureID))
        let childDefaults = try #require(UserDefaults(suiteName: childID))
        let ownerKeychain = SharedKeychainStore(profileID: fixtureID)
        let childKeychain = SharedKeychainStore(profileID: childID)
        defer {
            fixtureDefaults.removePersistentDomain(forName: fixtureID)
            childDefaults.removePersistentDomain(forName: childID)
            cleanUp(keychain: ownerKeychain, connectionID: backendID)
            cleanUp(keychain: childKeychain, connectionID: backendID)
        }
        let config = ServerConfigStore(profileID: FamilyProfile.ownerID, defaults: fixtureDefaults)
        config.saveBackends([
            BackendConfig(
                id: backendID.uuidString, name: "Legacy fixture", type: .audiobookshelf,
                url: "https://legacy-fixture.invalid", token: nil, enabled: true,
                username: nil, password: nil, userId: nil, selectedLibraryIds: nil
            )
        ])
        let owner = ProviderConnectionStore(
            profileID: FamilyProfile.ownerID, defaults: fixtureDefaults, keychain: ownerKeychain,
            serverConfig: config, providerFactory: { _ in nil }
        )
        #expect(owner.connections.map(\.id) == [backendID])
        #expect(owner.backend(id: backendID.uuidString)?.name == "Legacy fixture")
        #expect(owner.allBackends().map(\.id) == [backendID.uuidString])
        let child = ProviderConnectionStore(
            profileID: childID, defaults: childDefaults, keychain: childKeychain,
            serverConfig: config, providerFactory: { _ in nil }
        )
        #expect(child.connections.isEmpty)
        #expect(child.backend(id: backendID.uuidString) == nil)
        #expect(child.allBackends().isEmpty)

        let ownerFallback = ProviderConnectionStore(
            profileID: FamilyProfile.ownerID, defaults: fixtureDefaults, keychain: ownerKeychain,
            serverConfig: config, initialConnections: [], providerFactory: { _ in nil }
        )
        #expect(ownerFallback.backend(id: backendID.uuidString)?.name == "Legacy fixture")
        #expect(ownerFallback.allBackends().map(\.id) == [backendID.uuidString])
    }

    @Test func directCodableKeepsExistingOwnerCredentialRouting() throws {
        let connectionID = UUID()
        defer { cleanUp(keychain: .shared, connectionID: connectionID) }
        let data = try JSONEncoder().encode(connection(id: connectionID, name: "Owner fixture", secret: "owner-secret"))
        #expect(SharedKeychainStore.shared.token(forConnectionId: connectionID.uuidString) == "owner-secret")
        let restored = try JSONDecoder().decode(ServerConnection.self, from: data)
        #expect(restored.token == "owner-secret")
        #expect(restored.customHeaders?["X-API-Key"] == "owner-secret")
    }

    private func connection(id: UUID, name: String, secret: String) -> ServerConnection {
        ServerConnection(
            id: id, name: name, url: "https://profiles-test.invalid", type: .audiobookshelf,
            password: secret, token: secret,
            customHeaders: ["X-API-Key": secret, "Accept": "application/json"],
            plexHomeUserToken: secret, plexOwnerToken: secret
        )
    }

    private func cleanUp(keychain: SharedKeychainStore, connectionID: UUID) {
        keychain.deleteAll(forConnectionId: connectionID.uuidString)
        keychain.deleteCustomHeaderValues(headerNames: ["X-API-Key"], forConnectionId: connectionID.uuidString)
    }
}
