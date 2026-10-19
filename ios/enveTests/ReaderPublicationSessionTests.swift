import Foundation
import Testing

@testable import enve

@MainActor
struct ReaderPublicationSessionTests {
    @Test(arguments: ["cbz", "cbr", "epub", "pdf"])
    func existingLocalAssetsBypassServerSetup(_ fileExtension: String) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var book = Book(id: UUID().uuidString, title: "Issue", source: .kavita, mediaType: .ebook)
        book.ebookFileURL = url
        let session = ReaderPublicationSession(book: book, providerResolver: NoProviderResolver())

        #expect(session.hasLocalAsset)
        try FileManager.default.removeItem(at: url)
        #expect(!session.hasLocalAsset)
    }

    private let fixtureRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReaderPublicationSessionTests", isDirectory: true)

    private var managedRoots: [URL] {
        [
            fixtureRoot.appendingPathComponent("Documents/Ebooks", isDirectory: true),
            fixtureRoot.appendingPathComponent("Caches/ReaderEbooks", isDirectory: true),
        ]
    }

    @Test func unreadableServerAssetsInsideManagedRootsAreDiscarded() {
        for root in managedRoots {
            #expect(
                ReaderPublicationSession.isDiscardableAsset(
                    at: root.appendingPathComponent("book.epub"),
                    source: .booklore,
                    managedRoots: managedRoots
                )
            )
        }
    }

    @Test func importedLocalBooksAreNeverDiscarded() {
        #expect(
            !ReaderPublicationSession.isDiscardableAsset(
                at: managedRoots[0].appendingPathComponent("book.epub"),
                source: .local,
                managedRoots: managedRoots
            )
        )
    }

    @Test func assetsOutsideManagedRootsAreNeverDiscarded() {
        for url in [
            fixtureRoot.appendingPathComponent("Documents/EbooksArchive/book.epub"),
            managedRoots[0],
            fixtureRoot.appendingPathComponent("Documents/book.epub"),
        ] {
            #expect(
                !ReaderPublicationSession.isDiscardableAsset(
                    at: url,
                    source: .booklore,
                    managedRoots: managedRoots
                )
            )
        }
    }

    @Test func relativeComponentsResolveBeforeTheManagedRootCheck() {
        #expect(
            !ReaderPublicationSession.isDiscardableAsset(
                at: managedRoots[0].appendingPathComponent("../book.epub"),
                source: .booklore,
                managedRoots: managedRoots
            )
        )
    }
}

private final class NoProviderResolver: LibraryProviderResolving {
    func provider(for providerId: UUID) -> LibraryProvider? { nil }
    func provider(for book: Book) -> LibraryProvider? { nil }
}
