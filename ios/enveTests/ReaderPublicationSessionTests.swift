import Foundation
import Testing

@testable import enve

@MainActor
struct ReaderPublicationSessionTests {
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
