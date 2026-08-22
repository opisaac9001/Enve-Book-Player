import Foundation
import Testing

@testable import enve

@MainActor
struct ReaderPublicationSessionTests {
    private let managedRoots = [
        URL(fileURLWithPath: "/Documents/Ebooks", isDirectory: true),
        URL(fileURLWithPath: "/Caches/ReaderEbooks", isDirectory: true),
    ]

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
        for path in [
            "/Documents/EbooksArchive/book.epub",  // sibling directory sharing the root's prefix
            "/Documents/Ebooks",  // the root itself
            "/Documents/book.epub",
        ] {
            #expect(
                !ReaderPublicationSession.isDiscardableAsset(
                    at: URL(fileURLWithPath: path),
                    source: .booklore,
                    managedRoots: managedRoots
                )
            )
        }
    }

    @Test func relativeComponentsResolveBeforeTheManagedRootCheck() {
        #expect(
            !ReaderPublicationSession.isDiscardableAsset(
                at: URL(fileURLWithPath: "/Documents/Ebooks/../book.epub"),
                source: .booklore,
                managedRoots: managedRoots
            )
        )
    }
}
