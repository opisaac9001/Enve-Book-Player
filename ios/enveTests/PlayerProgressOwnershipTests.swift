import Foundation
import Testing

@testable import enve

@MainActor
struct PlayerProgressOwnershipTests {
    @Test func playerCheckpointsStayWithTheirProfileAndRejectRetiredCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profiles = [
            FamilyProfile(id: UUID().uuidString, name: "First", role: .adult),
            FamilyProfile(id: UUID().uuidString, name: "Second", role: .adult)
        ]
        let domains = profiles.map { "PlayerProgressOwnershipTests.\($0.id)" }
        defer {
            for domain in domains { UserDefaults.standard.removePersistentDomain(forName: domain) }
            try? FileManager.default.removeItem(at: root)
        }
        let sessions = try zip(profiles, domains).map { profile, domain in
            let directory = root.appendingPathComponent(profile.id)
            return try ProfileSession(
                profile: profile,
                storage: ProfileStorageLocations(
                    profileID: profile.id,
                    documentsDirectory: directory.appendingPathComponent("Documents"),
                    applicationSupportDirectory: directory.appendingPathComponent("ApplicationSupport"),
                    cachesDirectory: directory.appendingPathComponent("Caches")
                ),
                defaults: UserDefaults(suiteName: domain)!
            )
        }
        let services = sessions.map {
            PlayerProgressService(providerConnections: $0.providerConnections, profileSession: $0)
        }
        let book = Book(id: "same-book", title: "Profile checkpoint", source: .local)
        services[0].saveProgress(book: book, position: 30, duration: 300)
        services[1].saveProgress(book: book, position: 90, duration: 300)
        services[0].saveLastPlayedBookId("first-book")
        services[1].saveLastPlayedBookId("second-book")
        await sessions[0].retire()

        services[0].saveProgress(book: book, position: 250, duration: 300)
        services[0].saveLastPlayedBookId("stale-callback")
        await services[0].syncProgressToRemote(book: book, progress: 250)

        #expect(services[0].loadProgress(for: book)?.position == 30)
        #expect(services[1].loadProgress(for: book)?.position == 90)
        #expect(sessions[0].playerState.loadLastPlayedBookId() == "first-book")
        #expect(sessions[1].playerState.loadLastPlayedBookId() == "second-book")
        #expect(sessions[0].pendingSync.count == 0)
        #expect(sessions[1].pendingSync.count == 0)
        await sessions[1].retire()
    }
}
