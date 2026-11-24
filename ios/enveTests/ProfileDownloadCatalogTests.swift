import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
struct ProfileDownloadCatalogTests {
    @Test func lookupKeepsAccountIdentityAndBothLinkDirectionsWithoutUnrelatedRows() async throws {
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let audio = Book(id: "same-id", title: "Audio", backendId: "first", source: .silo)
        let duplicate = Book(id: "same-id", title: "Second connection", providerId: UUID(), backendId: "first", source: .silo)
        let otherAccount = Book(id: "same-id", title: "Other account", backendId: "second", source: .silo)
        var ebook = Book(id: "ebook", title: "Linked ebook", mediaType: .ebook, backendId: "first", source: .silo)
        ebook.linkedAudiobookStableId = audio.stableId
        let text = Book(id: "text", title: "Text", mediaType: .ebook, backendId: "fixture", source: .local)
        var narration = Book(id: "narration", title: "Narration", backendId: "fixture", source: .local)
        narration.readAloudSourceStableId = text.stableId
        let deleted = Book(id: "deleted", title: "Removed", backendId: "first", source: .silo)
        for book in [audio, duplicate, otherAccount, ebook, text, narration] { context.insert(BookRecord(from: book)) }
        let record = BookRecord(from: deleted)
        record.isDeleted = true
        context.insert(record)
        for index in 0..<1000 {
            context.insert(BookRecord(from: Book(id: "remote-\(index)", title: "Remote", backendId: "first", source: .silo)))
        }
        try context.save()
        let store = SwiftDataBookStore(container: container)
        let reverse = try await store.booksForDownloadImport(stableIds: [audio.stableId, text.stableId, deleted.stableId])
        #expect(audio.stableId == duplicate.stableId)
        #expect(audio.uniqueId != duplicate.uniqueId)
        #expect(Set(reverse.map(\.uniqueId)) == Set([audio, duplicate, ebook, text, narration].map(\.uniqueId)))
        let forward = try await store.booksForDownloadImport(stableIds: [ebook.stableId, narration.stableId])
        #expect(Set(forward.map(\.uniqueId)) == Set(reverse.map(\.uniqueId)))
        #expect(try await store.booksForDownloadImport(stableIds: []).isEmpty)
    }

    @Test func lookupBatchesLargeDownloadSetsAndHonorsCancellation() async throws {
        let schema = Schema(versionedSchema: BookStoreSchemaV2.self)
        let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let books = (0..<405).map { Book(id: "download-\($0)", title: "Book \($0)", backendId: "fixture", source: .local) }
        for book in books { context.insert(BookRecord(from: book)) }
        try context.save()
        let store = SwiftDataBookStore(container: container)
        let ids = Set(books.map(\.stableId))
        #expect(Set(try await store.booksForDownloadImport(stableIds: ids).map(\.stableId)) == ids)
        let task = Task { try await store.booksForDownloadImport(stableIds: ids) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
