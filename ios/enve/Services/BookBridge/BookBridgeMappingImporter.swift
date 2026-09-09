import Foundation
import Logging

@MainActor
final class BookBridgeMappingImporter {
    static let shared = BookBridgeMappingImporter()

    struct Result {
        var newLinks: Int = 0
        var alreadyLinked: Int = 0
        var ebookNotFound: Int = 0
        var audiobookNotFound: Int = 0
        var skippedUnlinked: Int = 0
    }

    private let client = BookBridgeClient()

    private init() {}

    func runImport(baseURL: URL) async throws -> Result {
        let mappings = try await client.fetchMappings(baseURL: baseURL)

        let audiobooksByABSId = Self.booksIndexedByUniqueKey(
            AppState.shared.allBooks.filter { $0.mediaType == .audiobook && $0.source == .audiobookshelf },
            key: { $0.id }
        )

        let ebooksByDocHash: [String: Book] = {
            let links = KOReaderSyncService.shared.links
            let booksByStableId = Self.booksIndexedByUniqueKey(
                AppState.shared.allBooks.filter { $0.mediaType == .ebook },
                key: { $0.stableId }
            )
            var map: [String: Book] = [:]
            for (stableId, link) in links {
                guard let book = booksByStableId[stableId] else { continue }
                map[link.documentHash.lowercased()] = book
            }
            return map
        }()

        var result = Result()

        for mapping in mappings {
            guard let absId = mapping.linkedABSId, !absId.isEmpty else {
                result.skippedUnlinked += 1
                continue
            }

            let docHash = mapping.documentHash.lowercased()

            guard let audiobook = audiobooksByABSId[absId] else {
                result.audiobookNotFound += 1
                AppLogger.sync.debug(
                    "[BookBridge] No Audiobookshelf match sourceId=\(DiagnosticLogSanitizer.identifier(for: absId))"
                )
                continue
            }

            guard let ebook = ebooksByDocHash[docHash] else {
                result.ebookNotFound += 1
                AppLogger.sync.debug(
                    "[BookBridge] No local ebook match documentId=\(DiagnosticLogSanitizer.identifier(for: docHash)) audiobookId=\(DiagnosticLogSanitizer.identifier(for: audiobook.stableId))"
                )
                continue
            }

            if ebook.linkedAudiobookStableId == audiobook.stableId {
                result.alreadyLinked += 1
                continue
            }

            _ = AppState.shared.mutateBook(stableId: ebook.stableId) { updated in
                updated.linkedAudiobookStableId = audiobook.stableId
            }
            result.newLinks += 1
            AppLogger.sync.debug(
                "[BookBridge] Linked ebookId=\(DiagnosticLogSanitizer.identifier(for: ebook.stableId)) audiobookId=\(DiagnosticLogSanitizer.identifier(for: audiobook.stableId))"
            )
        }

        EbookLinkStore.shared.saveLinks()
        return result
    }

    static func booksIndexedByUniqueKey<Key: Hashable>(
        _ books: [Book],
        key: (Book) -> Key
    ) -> [Key: Book] {
        var indexed: [Key: Book] = [:]
        var duplicateKeys = Set<Key>()

        for book in books {
            let bookKey = key(book)
            guard !duplicateKeys.contains(bookKey) else { continue }
            if indexed.updateValue(book, forKey: bookKey) != nil {
                indexed.removeValue(forKey: bookKey)
                duplicateKeys.insert(bookKey)
            }
        }

        return indexed
    }
}
