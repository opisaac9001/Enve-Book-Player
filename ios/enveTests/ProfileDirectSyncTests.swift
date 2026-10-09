import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileDirectSyncTests {
    @Test func disabledStorytellerSyncDoesNotResolveProvidersOrStagePositions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "direct-sync-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let profile = FamilyProfile(id: UUID().uuidString, name: "Reader", role: .adult)
        let storage = ProfileStorageLocations(profileID: profile.id,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches"),
            legacyPlaybackStoreURL: root.appendingPathComponent("default.store"))
        let session = try ProfileSession(profile: profile, storage: storage, defaults: defaults)
        let resolver = RecordingSyncProviderResolver()
        let ledger = StorytellerPositionLedger(defaults: defaults)
        let sync = StorytellerPositionSyncService(ledger: ledger, providerResolver: resolver,
            libraryCache: session.appState.libraryCache, serverSyncEnabled: { false })
        let book = Book(id: "shared-book", title: "Shared book", source: .storyteller)
        let locator = #"{"locations":{"totalProgression":0.4}}"#
        _ = try await sync.submit(book: book, locatorJSON: locator, observedAt: .now)
        _ = try await sync.submitAudioPosition(book: book, currentTime: 120, observedAt: .now)
        #expect(resolver.count == 0)
        #expect(ledger.pending(for: StorytellerPositionKey(book: book)) == nil)
        session.bookProgress.saveProgress(for: book, progress: 120, duration: 300)
        #expect(session.bookProgress.loadProgress(for: book)?.progress == 120)
        await session.retire()
    }
}

@MainActor
private final class RecordingSyncProviderResolver: LibraryProviderResolving {
    private(set) var count = 0
    func provider(for providerId: UUID) -> LibraryProvider? { count += 1; return nil }
    func provider(for book: Book) -> LibraryProvider? { count += 1; return nil }
}
