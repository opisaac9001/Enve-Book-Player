import Foundation
import Testing

@testable import enve

@MainActor
struct ProfileReaderSyncStoresTests {
    @Test func artifactMappingsRemainIndependentForIdenticalAccountAndBookIDs() throws {
        let domains = try Domains()
        defer { domains.remove() }
        let first = SiloReaderArtifactIDStore(defaults: domains.first)
        let second = SiloReaderArtifactIDStore(defaults: domains.second)
        let connection = UUID()
        first.setAnnotationRemoteID("first-remote", connectionID: connection, bookID: "42", localID: "annotation")
        first.setBookmarkRemoteID("first-bookmark", connectionID: connection, bookID: "42", localID: "bookmark")
        #expect(second.annotationRemoteID(connectionID: connection, bookID: "42", localID: "annotation") == nil)
        second.setAnnotationRemoteID("second-remote", connectionID: connection, bookID: "42", localID: "annotation")
        second.setBookmarkRemoteID("second-bookmark", connectionID: connection, bookID: "42", localID: "bookmark")
        first.removeAnnotationRemoteID(connectionID: connection, bookID: "42", localID: "annotation")
        #expect(second.annotationRemoteID(connectionID: connection, bookID: "42", localID: "annotation") == "second-remote")
        #expect(SiloReaderArtifactIDStore(defaults: domains.first).bookmarkRemoteID(connectionID: connection, bookID: "42", localID: "bookmark") == "first-bookmark")
        #expect(SiloReaderArtifactIDStore(defaults: domains.second).bookmarkRemoteID(connectionID: connection, bookID: "42", localID: "bookmark") == "second-bookmark")
    }

    @Test func browseThresholdAndDeletedBooksRemainInTheirCapturedPreferences() async throws {
        let domains = try Domains()
        defer { domains.remove() }
        let firstBrowse = RemoteLibraryBrowseStore(defaults: domains.first)
        let secondBrowse = RemoteLibraryBrowseStore(defaults: domains.second)
        let firstDeleted = DeletedBooksTombstoneStore(defaults: domains.first)
        let secondDeleted = DeletedBooksTombstoneStore(defaults: domains.second)
        let connection = UUID()
        firstBrowse.record(providerId: connection, libraryId: "same", bookCount: 6000)
        firstDeleted.markDeleted("same-book", title: "First title")
        #expect(!secondBrowse.isRemoteBrowsed(providerId: connection, libraryId: "same"))
        #expect(secondDeleted.isEmpty)
        secondDeleted.markDeleted("same-book", title: "Second title")
        let lateWrite = Task { @MainActor in
            await Task.yield()
            firstDeleted.markRestored("same-book")
            firstBrowse.record(providerId: connection, libraryId: "same", bookCount: 7000)
        }
        await lateWrite.value
        #expect(secondDeleted.allEntries.first?.title == "Second title")
        #expect(DeletedBooksTombstoneStore(defaults: domains.first).isEmpty)
        #expect(DeletedBooksTombstoneStore(defaults: domains.second).isDeleted("same-book"))
        #expect(RemoteLibraryBrowseStore(defaults: domains.first).isRemoteBrowsed(providerId: connection, libraryId: "same"))
        secondDeleted.clearAll()
        #expect(firstBrowse.isRemoteBrowsed(providerId: connection, libraryId: "same"))
    }

    @Test func annotationRetryQueuesDoNotReadOrWriteAnotherProfile() throws {
        let domains = try Domains()
        defer { domains.remove() }
        let resolver = NoProviders()
        let first = AnnotationSyncService(
            defaults: domains.first, providerResolver: resolver,
            readerArtifacts: ReaderArtifactsStore(defaults: domains.first)
        )
        let second = AnnotationSyncService(
            defaults: domains.second, providerResolver: resolver,
            readerArtifacts: ReaderArtifactsStore(defaults: domains.second)
        )
        first.enqueue(.createAnnotation(bookId: "same-book", annotationId: "same-id"))
        #expect(second.pendingOperationCount == 0)
        second.enqueue(.createBookmark(bookId: "same-book", bookmarkId: "same-id"))
        first.enqueue(.deleteAnnotation(remoteId: 1))
        #expect(first.pendingOperationCount == 2)
        #expect(second.pendingOperationCount == 1)
        #expect(AnnotationSyncService(
            defaults: domains.first, providerResolver: resolver,
            readerArtifacts: ReaderArtifactsStore(defaults: domains.first)
        ).pendingOperationCount == 2)
        #expect(AnnotationSyncService(
            defaults: domains.second, providerResolver: resolver,
            readerArtifacts: ReaderArtifactsStore(defaults: domains.second)
        ).pendingOperationCount == 1)
    }

    private final class NoProviders: LibraryProviderResolving {
        func provider(for providerId: UUID) -> LibraryProvider? { nil }
        func provider(for book: Book) -> LibraryProvider? { nil }
    }

    private struct Domains {
        let firstName = "com.enve.tests.reader.profile.\(UUID().uuidString)"
        let secondName = "com.enve.tests.reader.profile.\(UUID().uuidString)"
        let first: UserDefaults
        let second: UserDefaults

        init() throws {
            first = try #require(UserDefaults(suiteName: firstName))
            second = try #require(UserDefaults(suiteName: secondName))
        }

        func remove() {
            first.removePersistentDomain(forName: firstName)
            second.removePersistentDomain(forName: secondName)
        }
    }
}
