import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
struct BookStoreConfigurationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ENVE_PERSISTENCE_DIAGNOSTIC"] == "1"))
    func reopeningProfilesKeepsBooksProgressAndBookmarksIndependent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "com.enve.tests.database-switch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: domain)
        }
        let childID = UUID().uuidString
        let providerID = UUID()

        func visit(profileID: String, title: String, iteration: Int) async throws {
            let storage = ProfileStorageLocations(
                profileID: profileID,
                documentsDirectory: root.appendingPathComponent("Documents"),
                applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
                cachesDirectory: root.appendingPathComponent("Caches")
            )
            let manager = try BookStoreManager(storage: storage, defaults: defaults)
            let store = manager.repository
            let book = Book(id: "same-book", title: title, source: .local, backendId: "fixture", providerId: providerID, libraryId: "fixture")
            if iteration == 1 {
                #expect(await store.bookCount() == 0)
                await store.upsertBooks([book])
            } else {
                let restored = try #require(await store.book(uniqueId: book.uniqueId))
                #expect(restored.title == title)
                #expect(restored.currentTime == Double(iteration - 1) * 30)
                let bookmarks = await store.bookmarks(forBookStableId: book.stableId)
                #expect(bookmarks.count == iteration - 1)
                #expect(bookmarks.allSatisfy { $0.title == title })
                #expect(Set(bookmarks.map(\.position)) == Set((1..<iteration).map { Double($0) * 30 }))
            }
            await store.updateProgress(uniqueId: book.uniqueId, currentTime: Double(iteration) * 30, isFinished: false, lastUpdate: Date())
            await store.upsertBookmark(Bookmark(bookId: book.id, position: Double(iteration) * 30, title: title, mediaType: .audiobook), bookStableId: book.stableId)
            #expect(await store.bookCount() == 1)
            #expect(await store.book(uniqueId: book.uniqueId)?.currentTime == Double(iteration) * 30)
        }

        for iteration in 1...11 {
            try await visit(profileID: FamilyProfile.ownerID, title: "Owner", iteration: iteration)
            try await visit(profileID: childID, title: "Child", iteration: iteration)
        }
    }

    @Test func simultaneousProfileContainersSaveToTheirOwnStores() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let configuration = ModelConfiguration("BookStore", schema: schema, url: root.appendingPathComponent("BookStore.sqlite"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, migrationPlan: BookStoreMigrationPlan.self, configurations: [configuration])
        _ = try BookStoreSQLTuner.apply(to: configuration.url)
        let book = Book(id: "direct", title: "Direct", source: .local, backendId: "fixture", providerId: UUID(), libraryId: "fixture")
        let repository = SwiftDataBookStore(container: container)
        let secondSchema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let secondConfiguration = ModelConfiguration("BookStoreSecond", schema: secondSchema, url: root.appendingPathComponent("Second.sqlite"), cloudKitDatabase: .none)
        let second = try ModelContainer(for: secondSchema, migrationPlan: BookStoreMigrationPlan.self, configurations: [secondConfiguration])
        let secondRepository = SwiftDataBookStore(container: second)
        await secondRepository.upsertBooks([book])
        await repository.upsertBooks([book])
        let other = Book(id: "worker", title: "Worker", source: .local, backendId: "fixture", providerId: UUID(), libraryId: "fixture")
        await repository.upsertBooks([other])
        #expect(await repository.bookCount() == 2)
        #expect(await secondRepository.bookCount() == 1)
    }
}
