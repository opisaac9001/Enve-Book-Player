import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
struct DownloadCatalogLookupTests {
    @Test func persistentLookupMatchesSanitizedFoldersAndExcludesDeletedAndEbooks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("BookStore.sqlite")
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)
        let owner = UUID()
        let audio = Book(id: "path/with\\colon:and?query&x=1", title: "Downloaded",
                         libraryId: "books", providerId: owner, source: .silo)
        let ebook = Book(id: "ebook", title: "Ebook", mediaType: .ebook,
                         libraryId: "books", providerId: owner, source: .silo)
        let deleted = Book(id: "deleted", title: "Deleted", libraryId: "books", providerId: owner, source: .silo)
        context.insert(BookRecord(from: audio))
        context.insert(BookRecord(from: ebook))
        let deletedRecord = BookRecord(from: deleted)
        deletedRecord.isDeleted = true
        context.insert(deletedRecord)
        try context.save()
        let keys = Set([audio, ebook, deleted].map { LocalStorageManager.sanitizedId(for: $0.stableId) })

        #expect(try BookStoreSQLTuner.downloadedAudiobookIDs(at: url, storageKeys: keys) == [audio.stableId])
        #expect(try BookStoreSQLTuner.downloadedAudiobookIDs(at: url, storageKeys: []).isEmpty)
        let store = SwiftDataBookStore(container: container)
        #expect(await store.downloadedAudiobooks(storageKeys: keys).map(\.uniqueId) == [audio.uniqueId])
    }
}
