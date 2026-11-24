import Foundation
import Testing

@testable import enve

@MainActor
@Suite(.timeLimit(.minutes(2)))
struct ConnectionConfigurationHealthTests {
    private static let storageKey = "enve_server_connections"
    private static let unreadable = Data("{not a connection list".utf8)

    @Test func unreadableConfigurationIsNotAuthoritativeAndIsPreserved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.defaults.set(Self.unreadable, forKey: Self.storageKey)

        let session = try fixture.session()
        #expect(!session.providerConnections.isConfigurationAuthoritative)
        #expect(session.providerConnections.connections.isEmpty)
        session.providerConnections.refresh()
        #expect(!session.providerConnections.isConfigurationAuthoritative)
        #expect(fixture.defaults.data(forKey: Self.storageKey) == Self.unreadable)
        #expect(fixture.defaults.data(forKey: "\(Self.storageKey).unreadable") == Self.unreadable)

        let connection = ServerConnection(name: "Recovered", url: "https://recovered.invalid", type: .opds)
        let encoder = JSONEncoder()
        encoder.userInfo[ServerConnection.keychainUserInfoKey] = session.keychain
        fixture.defaults.set(try encoder.encode([connection]), forKey: Self.storageKey)
        fixture.defaults.removeObject(forKey: "\(Self.storageKey).unreadable")
        session.providerConnections.refresh()
        #expect(session.providerConnections.isConfigurationAuthoritative)
        #expect(session.providerConnections.connections.map(\.id) == [connection.id])
        await session.retire()
    }

    @Test func startupKeepsRemoteCatalogWhenConnectionsAreUnreadable() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.defaults.set(Self.unreadable, forKey: Self.storageKey)
        let session = try fixture.session()
        let book = Book(id: "remote-42", title: "Cached remote", source: .audiobookshelf, providerId: UUID(), libraryId: "library")
        await session.bookStore.upsertBooks([book])

        session.start()
        try await fixture.waitForBootstrap(session)
        try await Task.sleep(for: .seconds(1))

        #expect(await session.bookStore.book(stableId: book.stableId) != nil)
        await session.retire()
    }

    @Test func savingPartialConnectionsCannotReenablePurgingAfterRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.defaults.set(Self.unreadable, forKey: Self.storageKey)
        let first = try fixture.session()
        first.providerConnections.connections = [ServerConnection(name: "Readded", url: "https://fixture.invalid", type: .opds)]
        await first.retire()

        let second = try fixture.session()
        #expect(!second.providerConnections.isConfigurationAuthoritative)
        #expect(second.providerConnections.connections.count == 1)
        #expect(fixture.defaults.data(forKey: "\(Self.storageKey).unreadable") == Self.unreadable)
        await second.retire()
    }

    @Test func startupStillPurgesUnknownProvidersAfterAnAuthoritativeLoad() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let session = try fixture.session()
        #expect(session.providerConnections.isConfigurationAuthoritative)
        let book = Book(id: "orphan-42", title: "Orphaned remote", source: .audiobookshelf, providerId: UUID(), libraryId: "library")
        await session.bookStore.upsertBooks([book])

        session.start()
        try await fixture.waitForBootstrap(session)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while await session.bookStore.book(stableId: book.stableId) != nil {
            try #require(ContinuousClock.now < deadline, "Orphan purge never ran")
            try await Task.sleep(for: .milliseconds(50))
        }
        await session.retire()
    }

    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "connection-health-\(UUID().uuidString)"
        let profile = FamilyProfile(id: UUID().uuidString, name: "Reader", role: .child)
        let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: suite))
        }

        func session() throws -> ProfileSession {
            let storage = ProfileStorageLocations(profileID: profile.id,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: root.appendingPathComponent("Caches"))
            return try ProfileSession(profile: profile, storage: storage, defaults: defaults)
        }

        func waitForBootstrap(_ session: ProfileSession) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !session.appState.isBootstrapComplete {
                try #require(ContinuousClock.now < deadline, "Startup never completed")
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        func remove() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
