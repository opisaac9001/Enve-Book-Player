import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileLibraryStoresTests {
    @Test func collectionsAndSavedMutationsRemainSeparateAfterReopening() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = UserCollectionStore(defaults: fixture.ownerDefaults)
        let child = UserCollectionStore(defaults: fixture.childDefaults)
        let collection = Collection(
            id: "same-collection", name: "Owner", description: nil, books: ["same-book"],
            bookCount: 1, iconName: "books.vertical", color: "orange", providerId: nil
        )
        owner.save(collection)
        #expect(child.collections.isEmpty)
        child.save(Collection(
            id: collection.id, name: "Child", description: nil, books: [],
            bookCount: 0, iconName: "books.vertical", color: "orange", providerId: nil
        ))
        child.clearAll()
        #expect(UserCollectionStore(defaults: fixture.ownerDefaults).collections == [collection])
        #expect(UserCollectionStore(defaults: fixture.childDefaults).collections.isEmpty)

        let smart = SmartCollection(
            id: "same-smart", name: "Owner smart", description: nil,
            rules: SmartCollectionRuleGroup(logicOperator: .and, rules: []),
            iconName: "books.vertical", color: "orange", isSystem: false, sortOrder: 0
        )
        SmartCollectionStore(defaults: fixture.ownerDefaults).save(smart)
        let childSmart = SmartCollectionStore(defaults: fixture.childDefaults)
        #expect(childSmart.userCollections.isEmpty)
        childSmart.save(smart)
        childSmart.clearAll()
        #expect(SmartCollectionStore(defaults: fixture.ownerDefaults).userCollections == [smart])
        #expect(SmartCollectionStore(defaults: fixture.childDefaults).userCollections.isEmpty)

        let ownerSaved = SavedBooksStore(defaults: fixture.ownerDefaults)
        let childSaved = SavedBooksStore(defaults: fixture.childDefaults)
        ownerSaved.set("same-book", in: .favorites, saved: true, enqueue: true)
        let delayed = Task { @MainActor in
            await Task.yield()
            ownerSaved.set("same-book", in: .later, saved: true, enqueue: true)
        }
        childSaved.set("same-book", in: .favorites, saved: true, enqueue: true)
        childSaved.set("same-book", in: .favorites, saved: false, enqueue: false)
        await delayed.value
        let reopenedOwner = SavedBooksStore(defaults: fixture.ownerDefaults)
        let reopenedChild = SavedBooksStore(defaults: fixture.childDefaults)
        #expect(reopenedOwner.favorites == ["same-book"])
        #expect(reopenedOwner.later == ["same-book"])
        #expect(reopenedOwner.pending.count == 2)
        #expect(reopenedChild.favorites.isEmpty)
        #expect(reopenedChild.later.isEmpty)
        #expect(reopenedChild.pending.isEmpty)
    }

    @Test func lastOpenedDismissalWorkAndSeriesUseCapturedPreferences() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let book = Book(id: "same-book", title: "Book", backendId: "local", source: .local)
        let date = Date(timeIntervalSince1970: 1234)
        let ownerLast = LastOpenedBookStore(defaults: fixture.ownerDefaults)
        let childLast = LastOpenedBookStore(defaults: fixture.childDefaults)
        ownerLast.record(book, at: date)
        #expect(childLast.stableId == nil)
        childLast.record(book, at: date.addingTimeInterval(100))
        childLast.clear()
        let reopened = LastOpenedBookStore(defaults: fixture.ownerDefaults)
        #expect(reopened.stableId == book.stableId)
        #expect(reopened.openedAt == date)
        #expect(LastOpenedBookStore(defaults: fixture.childDefaults).stableId == nil)

        HearthDismissedShelfStore(defaults: fixture.ownerDefaults).insert(stableId: "owner-book")
        HearthDismissedShelfStore(defaults: fixture.childDefaults).insert(stableId: "child-book")
        #expect(HearthDismissedShelfStore(defaults: fixture.ownerDefaults).stableIds == ["owner-book"])
        #expect(HearthDismissedShelfStore(defaults: fixture.childDefaults).stableIds == ["child-book"])

        let ownerWork = WorkOverrideStore(defaults: fixture.ownerDefaults)
        let childWork = WorkOverrideStore(defaults: fixture.childDefaults)
        ownerWork.merge(stableIds: [book.stableId], intoComputedWorkKey: "owner-work")
        ownerWork.dismissSuggestion(id: "same-suggestion")
        #expect(childWork.isEmpty)
        #expect(!childWork.isDismissed(suggestionId: "same-suggestion"))
        childWork.split(stableId: book.stableId)
        #expect(WorkOverrideStore(defaults: fixture.ownerDefaults).override(forStableId: book.stableId) == .mergeInto("owner-work"))
        #expect(WorkOverrideStore(defaults: fixture.childDefaults).override(forStableId: book.stableId) == .split)
        childWork.clear(stableId: book.stableId)
        #expect(!ownerWork.isEmpty)

        SeriesAliasStore(defaults: fixture.ownerDefaults).add(displayName: "Same series", aliases: ["Owner"])
        let childSeries = SeriesAliasStore(defaults: fixture.childDefaults)
        #expect(childSeries.aliases.isEmpty)
        childSeries.add(displayName: "Same series", aliases: ["Child"])
        #expect(SeriesAliasStore(defaults: fixture.ownerDefaults).aliases["Same series"] == ["Owner"])
        #expect(SeriesAliasStore(defaults: fixture.childDefaults).aliases["Same series"] == ["Child"])
        childSeries.remove(displayName: "Same series")
        #expect(SeriesAliasStore(defaults: fixture.ownerDefaults).aliases["Same series"] == ["Owner"])
    }

    @Test func podcastSubscriptionsWithIdenticalFeedURLsStayIndependent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = PodcastSubscriptionStore(defaults: fixture.ownerDefaults)
        let child = PodcastSubscriptionStore(defaults: fixture.childDefaults)
        let subscription = PodcastSubscription(
            id: "same-feed", title: "Owner feed", feedURL: "https://example.invalid/feed",
            dateSubscribed: Date(timeIntervalSince1970: 1234)
        )
        owner.subscribe(subscription)
        #expect(child.feeds.isEmpty)
        var childSubscription = subscription
        childSubscription.title = "Child feed"
        child.subscribe(childSubscription)
        #expect(PodcastSubscriptionStore(defaults: fixture.childDefaults).feeds == [childSubscription])
        child.unsubscribe(feedURL: subscription.feedURL)
        #expect(PodcastSubscriptionStore(defaults: fixture.childDefaults).feeds.isEmpty)
        #expect(PodcastSubscriptionStore(defaults: fixture.ownerDefaults).feeds == [subscription])
    }

    @Test func localLibrariesScansAndBookmarksCaptureTheirProfile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let owner = LocalLibraryStorageStore(defaults: fixture.ownerDefaults, storage: fixture.ownerStorage)
        let child = LocalLibraryStorageStore(defaults: fixture.childDefaults, storage: fixture.childStorage)
        let library = LocalLibrary(id: "same-library", name: "Owner library", folderPath: "/fixture")
        owner.saveLibrary(library)
        #expect(child.loadLibraries().isEmpty)
        child.saveLibrary(LocalLibrary(id: library.id, name: "Child library", folderPath: "/child-fixture"))
        owner.saveBookmark(Data([1]), for: library.id)
        child.saveBookmark(Data([2]), for: library.id)
        let localPath = fixture.childStorage.documentsDirectory.appendingPathComponent("Ebooks/local/book.epub").path
        let serverPath = fixture.childStorage.documentsDirectory.appendingPathComponent("Ebooks/server.epub").path
        let files = [localPath, serverPath].map {
            LocalBookFile(id: $0, fileName: "book.epub", filePath: $0, fileSize: 20, format: "epub")
        }
        child.saveScanResult(LocalLibraryScanResult(
            localLibraryId: library.id, booksFound: files, skippedFiles: [], scanDuration: 1, scannedAt: Date()
        ))
        #expect(child.loadBooks(libraryId: library.id).map(\.filePath) == [localPath])
        #expect(owner.loadBooks(libraryId: library.id).isEmpty)
        let reopened = LocalLibraryStorageStore(defaults: fixture.childDefaults, storage: fixture.childStorage)
        #expect(reopened.loadBookmark(for: library.id) == Data([2]))
        #expect(reopened.loadLibraries().first?.name == "Child library")
        #expect(reopened.loadBooks(libraryId: library.id).map(\.filePath) == [localPath])
        reopened.deleteBookmark(for: library.id)
        reopened.deleteBooks(libraryId: library.id)
        reopened.deleteLibrary(id: library.id)
        #expect(owner.loadBookmark(for: library.id) == Data([1]))
        #expect(owner.loadLibraries() == [library])
        #expect(reopened.loadLibraries().isEmpty)
        #expect(reopened.loadBooks(libraryId: library.id).isEmpty)
    }

    private struct Fixture {
        let ownerName: String
        let childName: String
        let ownerDefaults: UserDefaults
        let childDefaults: UserDefaults
        let ownerStorage: ProfileStorageLocations
        let childStorage: ProfileStorageLocations

        init() throws {
            ownerName = "ProfileLibraryStoresTests.owner.\(UUID().uuidString)"
            childName = "ProfileLibraryStoresTests.child.\(UUID().uuidString)"
            ownerDefaults = try #require(UserDefaults(suiteName: ownerName))
            childDefaults = try #require(UserDefaults(suiteName: childName))
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            func storage(_ id: String) -> ProfileStorageLocations {
                ProfileStorageLocations(
                    profileID: id, documentsDirectory: root.appendingPathComponent("Documents"),
                    applicationSupportDirectory: root.appendingPathComponent("ApplicationSupport"),
                    cachesDirectory: root.appendingPathComponent("Caches"),
                    legacyPlaybackStoreURL: root.appendingPathComponent("default.store")
                )
            }
            ownerStorage = storage(FamilyProfile.ownerID)
            childStorage = storage(UUID().uuidString)
        }

        func remove() {
            ownerDefaults.removePersistentDomain(forName: ownerName)
            childDefaults.removePersistentDomain(forName: childName)
        }
    }
}
