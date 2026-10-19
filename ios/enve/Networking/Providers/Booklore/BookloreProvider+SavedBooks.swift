import Foundation
import Logging

extension BookloreProvider {
    func updatePersonalRating(for book: Book, rating: Int) async throws {
        guard supportsPersonalRating else {
            throw ProviderError.notImplemented
        }
        guard let numericId = Int(grimmoryNumericId(book)) else {
            throw ProviderError.serverError("Unrecognized Grimmory book id")
        }

        struct RatingRequest: Encodable {
            let ids: [Int]
            let rating: Int
        }

        var request = try makeRequest(path: "/api/v1/books/personal-rating", method: "PUT")
        request.httpBody = try JSONEncoder().encode(RatingRequest(ids: [numericId], rating: min(max(rating, 1), 5) * 2))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await performAuthorizedRequest(request)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update Grimmory rating (HTTP \(response.statusCode))")
        }
    }

    func canSyncSavedBooks() async throws -> Bool {
        !useLegacyRestAPI && !useKomgaFallback
    }

    func relatedSavedBookIDs(for book: Book) -> Set<String> {
        guard !useLegacyRestAPI, !useKomgaFallback else { return [book.uniqueId] }
        let numericId = grimmoryNumericId(book)
        return ["\(book.providerId)_\(numericId)", "\(book.providerId)_\(Self.companionAudiobookIDPrefix)\(numericId)"]
    }

    func localSavedBookIDs(_ serverIDs: Set<String>, existingIDs: Set<String>, availableIDs: Set<String>) -> Set<String> {
        guard !useLegacyRestAPI, !useKomgaFallback else { return serverIDs }
        var result = Set<String>()
        for id in serverIDs {
            let companionId = Self.companionAudiobookIDPrefix + id
            if existingIDs.contains(companionId) {
                result.insert(companionId)
            } else if existingIDs.contains(id) || availableIDs.contains(id) || !availableIDs.contains(companionId) {
                result.insert(id)
            } else {
                result.insert(companionId)
            }
        }
        return result
    }

    func fetchSavedBookIDs(libraryIds: Set<String>) async throws -> [SavedBookList: Set<String>] {
        let collections = try await fetchCollections(libraryId: nil)
        var snapshot: [SavedBookList: Set<String>] = [:]
        for list in SavedBookList.allCases {
            let name = list == .favorites ? "Favorites" : "Enve For Later"
            let shelf = collections.first {
                $0.description != "Magic Shelf"
                    && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            }
            if let shelf {
                guard shelf.books.count == shelf.bookCount else { throw ProviderError.invalidResponse }
                snapshot[list] = Set(shelf.books)
            } else {
                snapshot[list] = []
            }
        }
        return snapshot
    }

    func setSavedBook(_ book: Book, list: SavedBookList, saved: Bool) async throws {
        guard !useLegacyRestAPI, !useKomgaFallback else { throw ProviderError.notImplemented }
        let name = list == .favorites ? "Favorites" : "Enve For Later"
        let shelf = try await fetchGrimmoryShelves().first {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        let shelfId: Int
        if let shelf {
            shelfId = shelf.id
        } else if saved {
            shelfId = try await createShelf(name: name, icon: list == .favorites ? "heart" : "bookmark").id
        } else {
            return
        }

        guard let bookId = Int(grimmoryNumericId(book)) else {
            throw ProviderError.invalidResponse
        }
        struct Assignment: Encodable {
            let bookIds: [Int]
            let shelvesToAssign: [Int]
            let shelvesToUnassign: [Int]
        }
        let payload = Assignment(
            bookIds: [bookId],
            shelvesToAssign: saved ? [shelfId] : [],
            shelvesToUnassign: saved ? [] : [shelfId]
        )
        let request = try makeRequest(
            path: "/api/v1/books/shelves",
            method: "POST",
            body: JSONEncoder().encode(payload),
            contentType: "application/json"
        )
        let (_, response) = try await performAuthorizedRequest(request)
        guard (200...204).contains(response.statusCode) else {
            throw ProviderError.serverError("Failed to update Grimmory shelf (HTTP \(response.statusCode))")
        }
    }
}
