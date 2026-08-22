import Foundation
import SwiftData
import Testing

@testable import enve

@MainActor
private final class LinkNoopWriter: BookWriting {
    func upsertBooks(_ books: [Book]) async {}
    func replaceLibrary(books: [Book], libraryId: String, providerId: UUID, allowSparseResult: Bool) async {}
    func deleteBooksFromUnknownProviders(validProviderIds: Set<String>) async -> Int { 0 }
    func deleteBooksFromInactiveLibraries(
        validProviderIds: Set<String>,
        restrictedLibraryIds: [String: Set<String>]
    ) async -> Int { 0 }
    func updateEbookFileURL(uniqueId: String, url: URL?) async {}
    func setHidden(_ hidden: Bool, stableId: String) async {}
    func setDeleted(_ deleted: Bool, stableId: String) async {}
    func deleteBooks(uniqueIds: Set<String>) async {}
    func importLegacyBooks(_ books: [Book], hiddenStableIds: Set<String>, deletedStableIds: Set<String>) async {}
    func clearAllData() async {}
}

@MainActor
struct EbookLinkStoreTests {
    @Test func savedLinksAreRestoredOntoTheLibraryMirror() async throws {
        let store = try makeStore()
        let library = LibraryBookCache(writer: LinkNoopWriter())
        let audiobook = makeBook(id: "audio", mediaType: .audiobook)
        var ebook = makeBook(id: "text", mediaType: .ebook)
        ebook.linkedAudiobookStableId = audiobook.stableId
        ebook.linkedAudiobookChapterOffset = 2
        library.books = [audiobook, ebook]
        await store.upsertBooks([audiobook, ebook])

        let links = EbookLinkStore(library: library, repository: store, books: store)
        await links.saveLinks()?.value

        library.mutateBook(uniqueId: ebook.uniqueId) {
            $0.linkedAudiobookStableId = nil
            $0.linkedAudiobookChapterOffset = 0
        }
        await links.reapplyLinks()

        #expect(library.books[1].linkedAudiobookStableId == audiobook.stableId)
        #expect(library.books[1].linkedAudiobookChapterOffset == 2)
    }

    @Test func linksPointingAtAMissingAudiobookAreNotApplied() async throws {
        let store = try makeStore()
        let library = LibraryBookCache(writer: LinkNoopWriter())
        let ebook = makeBook(id: "text", mediaType: .ebook)
        library.books = [ebook]
        await store.upsertBooks([ebook])
        await store.importLegacyLinks([
            (ebookStableId: ebook.stableId, audiobookStableId: "audiobookshelf:missing", chapterOffset: 1)
        ])

        let links = EbookLinkStore(library: library, repository: store, books: store)
        await links.reapplyLinks()

        #expect(library.books[0].linkedAudiobookStableId == nil)
    }

    private func makeStore() throws -> SwiftDataBookStore {
        let schema = Schema([
            BookRecord.self,
            MediaProgressRecord.self,
            LinkedBookPairRecord.self,
            BookmarkRecord.self,
            AnnotationRecord.self,
            ChapterCacheRecord.self,
        ])
        let configuration = ModelConfiguration(
            "EbookLinkStoreTests-\(UUID().uuidString)",
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
        return SwiftDataBookStore(container: try ModelContainer(for: schema, configurations: [configuration]))
    }

    private func makeBook(id: String, mediaType: AppMediaType) -> Book {
        Book(
            id: id,
            title: "Book \(id)",
            source: .audiobookshelf,
            mediaType: mediaType,
            providerId: UUID(uuidString: "3D1F5F1E-6C5B-4E3E-9C2A-9F52A0F6A333")!,
            libraryId: "library"
        )
    }
}
