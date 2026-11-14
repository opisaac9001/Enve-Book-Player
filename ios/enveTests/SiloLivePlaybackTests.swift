import Foundation
import Testing

@testable import enve

@MainActor
struct SiloLivePlaybackTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_SILO_LIVE_CONFIG"] != nil))
    func multipartPlaybackCrossesFileBoundary() async throws {
        struct Configuration: Decodable {
            let url: String
            let username: String
            let password: String
            let title: String
        }
        let path = try #require(ProcessInfo.processInfo.environment["ENVE_SILO_LIVE_CONFIG"])
        let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let id = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(id)
        let suite = "silo-live-playback-\(id)"
        let storage = ProfileStorageLocations(
            profileID: id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("Support"),
            cachesDirectory: root.appendingPathComponent("Caches")
        )
        let session = try ProfileSession(
            profile: FamilyProfile(id: id, name: "Silo playback verification", role: .adult),
            storage: storage, defaults: UserDefaults(suiteName: suite)
        )
        let connection = ServerConnection(
            name: "Silo playback verification", url: config.url, type: .silo,
            username: config.username, password: config.password
        )
        let provider = SiloProvider(connection: connection, profileSession: session)
        let manager = session.playback.manager
        do {
            session.defaults.set(true, forKey: "profileServerSyncEnabled")
            try #require(await provider.validateConnection())
            session.providerConnections.connections = [connection]
            session.providerConnections[connection.id] = provider
            var books: [Book] = []
            for library in try await provider.fetchLibraries() {
                books += try await provider.fetchBooks(libraryId: library.id)
            }
            let summary = try #require(books.first { $0.title == config.title })
            let book = try await provider.fetchFullBookDetails(bookId: summary.id, libraryId: summary.libraryId)
            try #require(book.audioTracks?.count == 2)
            manager.playBook(book, provider: provider, startPosition: 58)
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            while manager.currentTime < 63, manager.playbackError == nil, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(manager.playbackError == nil)
            #expect(manager.isPlaying)
            #expect(manager.currentTime >= 63)
            manager.seek(to: 20)
            let seekDeadline = ContinuousClock.now.advanced(by: .seconds(20))
            while !(20..<25).contains(manager.currentTime), manager.playbackError == nil, ContinuousClock.now < seekDeadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(manager.playbackError == nil)
            #expect(manager.isPlaying)
            #expect((20..<25).contains(manager.currentTime))
            await session.retire()
        } catch {
            await session.retire()
            UserDefaults.standard.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
