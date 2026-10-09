import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileLibrarianIsolationTests {
    @Test func nonOwnerCannotReadOrChangeOwnerConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "librarian-profile-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let profile = FamilyProfile(id: UUID().uuidString, name: "Child", role: .child)
        let storage = ProfileStorageLocations(profileID: profile.id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"),
            legacyPlaybackStoreURL: root.appendingPathComponent("default.store"))
        let session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
        let book = Book(id: UUID().uuidString, title: "Shared server identity")
        let ownerMessage = LibrarianMessage(role: .user, text: "Owner conversation", scope: .previousChapter)
        let conversations = LibrarianConversationStore.shared
        conversations.saveMessages([ownerMessage], bookStableId: book.stableId)
        defer {
            conversations.clear(bookStableId: book.stableId)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let model = LibrarianChatModel(book: book, profileSession: session)
        #expect(model.messages.isEmpty)
        model.clearConversation()
        await model.send(question: "Child question", scope: .previousChapter, currentTime: 0)
        await model.sendCatchUp(currentTime: 0)
        #expect(model.messages.isEmpty)
        #expect(conversations.loadMessages(bookStableId: book.stableId).map(\.text) == ["Owner conversation"])
        await session.retire()
    }
}
