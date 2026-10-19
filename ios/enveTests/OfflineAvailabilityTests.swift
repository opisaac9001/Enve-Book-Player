import Foundation
import Testing

@testable import enve

@MainActor
struct OfflineAvailabilityTests {
    @Test(arguments: [Book.BookSource.kavita, .komga])
    func readingCacheAndOfflineDownloadsStayDistinct(source: Book.BookSource) async throws {
        let fixture = try OfflineAvailabilityFixture()
        let session = fixture.session
        let downloads = session.engine.downloads
        let bytes = Data(repeating: 17, count: 4096)
        let cached = try session.ebooks.cacheRemoteEbook(data: bytes, preferredFilename: "issue.cbz", bookIdentifier: "issue")
        var book = fixture.book(id: "issue", source: source, url: cached)
        await session.bookStore.upsertBooks([book])

        #expect(!downloads.isDownloaded(book))
        #expect(!downloads.isLibraryDownloaded(book))
        #expect(!session.engine.library.matchesStatus(book, status: .downloaded, downloadedIds: [book.stableId]))
        #expect(await session.bookStore.downloadedEbooks(limit: 10).isEmpty)
        #expect(await downloads.downloadedStorageItems().isEmpty)
        let model = LibraryModel(profileSession: session)
        await model.bootstrap()
        #expect(!model.isDownloaded(book))

        let offline = try session.ebooks.persistRemoteEbookForOffline(from: cached, bookIdentifier: book.id)
        book.ebookFileURL = offline
        await session.bookStore.upsertBooks([book])
        #expect(downloads.isDownloaded(book))
        #expect(downloads.isLibraryDownloaded(book))
        #expect(session.engine.library.matchesStatus(book, status: .downloaded, downloadedIds: []))
        #expect(await session.bookStore.downloadedEbooks(limit: 10).map(\.uniqueId) == [book.uniqueId])
        #expect(await downloads.downloadedStorageBytes() == Int64(bytes.count))
        await model.reload()
        #expect(model.isDownloaded(book))

        let result = await downloads.clearAllDownloads()
        #expect(result.removed == 1)
        #expect(result.remaining == 0)
        #expect(!downloads.isDownloaded(book))
        #expect(await session.bookStore.book(stableId: book.stableId)?.ebookFileURL == nil)
        #expect(await session.bookStore.downloadedEbooks(limit: 10).isEmpty)
        await model.reload()
        #expect(!model.isDownloaded(book))
        await fixture.close()
    }

    @Test func recentCacheEntriesDoNotHideAnOlderOfflineDownload() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let session = fixture.session
        let cached = try session.ebooks.cacheRemoteEbook(data: Data([1]), preferredFilename: "cached.cbz", bookIdentifier: "cache")
        let saved = session.ebooks.serverEbooksRoot.appendingPathComponent("saved-issue.cbz")
        try Data([2]).write(to: saved)
        var offline = fixture.book(id: "saved", url: saved)
        offline.lastUpdate = .distantPast
        let cachedBooks = (0..<205).map { fixture.book(id: "cached-\($0)", url: cached) }
        await session.bookStore.upsertBooks(cachedBooks + [offline])

        #expect(await session.bookStore.downloadedEbooks(limit: 1).map(\.uniqueId) == [offline.uniqueId])
        #expect(await session.bookStore.downloadedEbooks(limit: 0).isEmpty)
        await fixture.close()
    }

    @Test func importedOriginalIsAvailableUntilItsFileDisappearsAndCannotBeRemovedAsADownload() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let session = fixture.session
        let original = session.ebooks.localEbooksRoot.appendingPathComponent("original.cbz")
        try Data([1, 2, 3]).write(to: original)
        let book = fixture.book(id: "original", source: .local, url: original)
        await session.bookStore.upsertBooks([book])

        #expect(session.engine.downloads.isDownloaded(book))
        #expect(await session.bookStore.downloadedEbooks(limit: 1).map(\.uniqueId) == [book.uniqueId])
        #expect(await session.engine.downloads.downloadedStorageItems().isEmpty)
        await session.engine.downloads.removeDownload(for: book)
        #expect(FileManager.default.fileExists(atPath: original.path))
        try FileManager.default.removeItem(at: original)
        #expect(!session.engine.downloads.isDownloaded(book))
        #expect(await session.bookStore.downloadedEbooks(limit: 1).isEmpty)
        await fixture.close()
    }

    @Test func retainedReadaloudUsesTheSameAvailabilityAndStorageChecks() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let session = fixture.session
        let temp = fixture.root.appendingPathComponent("narrated.epub")
        let bytes = Data(repeating: 4, count: 2048)
        try bytes.write(to: temp)
        let url = try session.ebooks.cacheReadaloudEpub(tempURL: temp, bookId: "narrated")
        let book = fixture.book(id: "narrated", source: .storyteller, url: url)
        await session.bookStore.upsertBooks([book])
        #expect(session.engine.downloads.isDownloaded(book))
        #expect(await session.bookStore.downloadedEbooks(limit: 1).map(\.uniqueId) == [book.uniqueId])
        #expect(await session.engine.downloads.downloadedStorageBytes() == Int64(bytes.count))
        await session.engine.downloads.removeLibraryDownload(for: book)
        #expect(!session.engine.downloads.isDownloaded(book))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(await session.bookStore.book(stableId: book.stableId)?.ebookFileURL == nil)
        await fixture.close()
    }

    @Test func anotherProfilesFilesNeverEstablishOfflineAvailability() async throws {
        let first = try OfflineAvailabilityFixture()
        let second = try OfflineAvailabilityFixture()
        let url = first.session.ebooks.serverEbooksRoot.appendingPathComponent("shared-issue.cbz")
        try Data([1, 2, 3]).write(to: url)
        let book = first.book(id: "shared", url: url)
        await first.session.bookStore.upsertBooks([book])
        await second.session.bookStore.upsertBooks([book])

        #expect(first.session.engine.downloads.isDownloaded(book))
        #expect(!second.session.engine.downloads.isDownloaded(book))
        #expect(await second.session.bookStore.downloadedEbooks(limit: 1).isEmpty)
        #expect(await second.session.engine.downloads.downloadedStorageItems().isEmpty)
        await first.close()
        await second.close()
    }

    @Test func aCompletedQueueEntryCannotTurnReadingCacheIntoAnOfflineDownload() async throws {
        let fixture = try OfflineAvailabilityFixture(completedBookID: "stale")
        let session = fixture.session
        let cached = try session.ebooks.cacheRemoteEbook(data: Data([1]), preferredFilename: "issue.cbz", bookIdentifier: "stale")
        let book = fixture.book(id: "stale", url: cached)
        await session.bookStore.upsertBooks([book])
        #expect(session.engine.downloads.completedDownloadBookIds.contains(book.downloadKey))
        #expect(!session.engine.downloads.isDownloaded(book))
        let model = LibraryModel(profileSession: session)
        await model.bootstrap()
        #expect(!model.isDownloaded(book))
        #expect(await session.engine.downloads.downloadedStorageItems().isEmpty)
        await fixture.close()
    }

    @Test func libraryBadgesIncludeOfflineIssuesBeyondTheFirstThousand() async throws {
        let fixture = try OfflineAvailabilityFixture()
        let session = fixture.session
        var books: [Book] = []
        for index in 0..<1001 {
            let id = "saved-\(index)"
            let url = session.ebooks.serverEbooksRoot.appendingPathComponent("\(id)-issue.cbz")
            try Data([1]).write(to: url)
            books.append(fixture.book(id: id, url: url))
        }
        await session.bookStore.upsertBooks(books)
        let model = LibraryModel(profileSession: session)
        await model.bootstrap()
        #expect(books.allSatisfy { model.isDownloaded($0) })
        await fixture.close()
    }
}

@MainActor
struct OfflineAvailabilityFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let session: ProfileSession
    let providerID = UUID()

    init(completedBookID: String? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        suite = "offline-availability-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        let storage = ProfileStorageLocations(
            profileID: UUID().uuidString,
            documentsDirectory: root.appendingPathComponent("Documents"),
            applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
            cachesDirectory: root.appendingPathComponent("Caches")
        )
        if let completedBookID {
            let book = Book(id: completedBookID, title: "Issue", mediaType: .ebook,
                            libraryId: "comics", providerId: providerID, source: .komga)
            var task = BookDownloadTask.create(bookId: book.downloadKey, title: book.title, source: book.source)
            task.status = .completed
            task.progress = 1
            try UnifiedDownloadQueueStore(storage: storage).save([task])
        }
        session = try ProfileSession(
            profile: FamilyProfile(id: storage.profileID, name: "Offline fixture", role: .child),
            storage: storage,
            defaults: defaults
        )
    }

    func book(id: String, source: Book.BookSource = .komga, url: URL) -> Book {
        Book(id: id, title: "Issue \(id)", mediaType: .ebook, ebookFormat: url.pathExtension,
             ebookFileURL: url, libraryId: "comics", providerId: providerID, source: source)
    }

    func close() async {
        await session.retire()
        defaults.removePersistentDomain(forName: suite)
        if let domain = session.storage.preferencesDomain {
            defaults.removePersistentDomain(forName: domain)
        }
        try? FileManager.default.removeItem(at: root)
    }
}
