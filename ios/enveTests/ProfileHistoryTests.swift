import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileHistoryTests {
    @Test func identicalSessionIDsAndLateWritesRemainInTheirProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerDirectory = locations(FamilyProfile.ownerID, root: root).historyDirectory
        let childDirectory = locations(UUID().uuidString, root: root).historyDirectory
        let owner = try HistorySessionStore(directory: ownerDirectory)
        let child = try HistorySessionStore(directory: childDirectory)
        let ownerSession = session(duration: 120)
        let childSession = session(duration: 30)
        await owner.appendListeningSession(ownerSession)
        #expect(await child.loadListeningSessions().isEmpty)
        await child.appendListeningSession(childSession)
        await owner.appendReadingSession(ownerSession)

        #expect(await owner.loadListeningSessions() == [ownerSession])
        #expect(await child.loadListeningSessions() == [childSession])
        #expect(await child.loadReadingSessions().isEmpty)
        let restored = try HistorySessionStore(directory: childDirectory)
        #expect(await restored.loadListeningSessions() == [childSession])
        #expect(await restored.loadReadingSessions().isEmpty)
    }

    @Test func failedDestinationCreationPreservesOwnerHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerDirectory = locations(FamilyProfile.ownerID, root: root).historyDirectory
        let owner = try HistorySessionStore(directory: ownerDirectory)
        let original = session(duration: 120)
        await owner.appendListeningSession(original)
        let blocked = root.appendingPathComponent("blocked")
        try Data("blocked".utf8).write(to: blocked)
        #expect(throws: (any Error).self) {
            try HistorySessionStore(directory: blocked.appendingPathComponent("History"))
        }
        #expect(await owner.loadListeningSessions() == [original])
        let restored = try HistorySessionStore(directory: ownerDirectory)
        #expect(await restored.loadListeningSessions() == [original])
    }

    @Test func corruptDestinationDoesNotOverwriteHistoryOrLoadOwnerSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerDirectory = locations(FamilyProfile.ownerID, root: root).historyDirectory
        let childDirectory = locations(UUID().uuidString, root: root).historyDirectory
        let owner = try HistorySessionStore(directory: ownerDirectory)
        let original = session(duration: 120)
        await owner.appendListeningSession(original)
        try FileManager.default.createDirectory(at: childDirectory, withIntermediateDirectories: true)
        let childFile = childDirectory.appendingPathComponent("listening_sessions.json")
        let corrupt = Data("corrupt history".utf8)
        try corrupt.write(to: childFile)
        #expect(throws: (any Error).self) { try HistorySessionStore(directory: childDirectory) }
        #expect(try Data(contentsOf: childFile) == corrupt)
        #expect(await owner.loadListeningSessions() == [original])
    }

    private func locations(_ profileID: String, root: URL) -> ProfileStorageLocations {
        ProfileStorageLocations(
            profileID: profileID,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"),
            legacyPlaybackStoreURL: root.appendingPathComponent("default.store")
        )
    }

    private func session(duration: Int) -> HistorySession {
        HistorySession(
            id: "same-session", bookId: "same-connection:42", mediaType: "audiobook",
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_000 + Double(duration)),
            durationSeconds: duration, startProgress: 0, endProgress: 0.5, progressDelta: 0.5,
            startLocation: nil, endLocation: nil, pagesRead: nil, source: .local
        )
    }
}
