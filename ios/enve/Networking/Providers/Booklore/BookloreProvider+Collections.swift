import Foundation
import Logging

extension BookloreProvider {
    struct GrimmoryShelfSummary: Decodable {
        let id: Int
        let name: String
        let icon: String?
        let bookCount: Int?
        let publicShelf: Bool?

        private enum CodingKeys: String, CodingKey {
            case id, name, icon, bookCount, numberOfBooks, publicShelf
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            name = try container.decode(String.self, forKey: .name)
            icon = try container.decodeIfPresent(String.self, forKey: .icon)
            bookCount =
                try container.decodeIfPresent(Int.self, forKey: .bookCount)
                ?? container.decodeIfPresent(Int.self, forKey: .numberOfBooks)
            publicShelf = try container.decodeIfPresent(Bool.self, forKey: .publicShelf)
        }
    }

    private struct GrimmoryMagicShelfSummary: Decodable {
        let id: Int
        let name: String
    }

    func fetchShelfSummaries() async throws -> [GrimmoryShelfSummary] {
        let request = try makeRequest(path: "/api/v1/shelves")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Shelf discovery returned HTTP \(response.statusCode)")
        }
        return try JSONDecoder().decode([GrimmoryShelfSummary].self, from: data)
    }

    private func fetchMagicShelfSummaries() async throws -> [GrimmoryMagicShelfSummary] {
        let request = try makeRequest(path: "/api/magic-shelves")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Magic Shelf discovery returned HTTP \(response.statusCode)")
        }
        return try JSONDecoder().decode([GrimmoryMagicShelfSummary].self, from: data)
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] {
        guard !useLegacyRestAPI, !useKomgaFallback else {
            throw ProviderError.notImplemented
        }

        let shelves = try await fetchShelfSummaries()

        let regularShelves: [Collection] = try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            for shelf in shelves {
                group.addTask {
                    let ids = try await self.fetchShelfBookIds(
                        shelfId: shelf.id,
                        expectedBookCount: shelf.bookCount
                    )
                    return (shelf.id, ids)
                }
            }
            var bookIdsByShelf: [Int: [String]] = [:]
            for try await (shelfId, ids) in group {
                bookIdsByShelf[shelfId] = ids
            }
            return shelves.map { shelf in
                let ids = bookIdsByShelf[shelf.id] ?? []
                return Collection(
                    id: String(shelf.id),
                    name: shelf.name,
                    description: nil,
                    books: ids,
                    bookCount: ids.count,
                    iconName: "books.vertical",
                    color: "purple",
                    providerId: connection.id
                )
            }
        }

        let magicShelves = try await fetchMagicShelfSummaries()
        let magicCollections: [Collection] = try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            for shelf in magicShelves {
                group.addTask {
                    (shelf.id, try await self.fetchMagicShelfBookIds(shelfId: shelf.id))
                }
            }
            var bookIdsByShelf: [Int: [String]] = [:]
            for try await (shelfId, ids) in group {
                bookIdsByShelf[shelfId] = ids
            }
            return magicShelves.map { shelf in
                let ids = bookIdsByShelf[shelf.id] ?? []
                return Collection(
                    id: "magic-\(shelf.id)",
                    name: shelf.name,
                    description: "Magic Shelf",
                    books: ids,
                    bookCount: ids.count,
                    iconName: "wand.and.stars",
                    color: "indigo",
                    providerId: connection.id
                )
            }
        }

        var seenCollectionIds = Set<String>()
        return (regularShelves + magicCollections).filter {
            seenCollectionIds.insert("\($0.providerId?.uuidString ?? "")-\($0.id)").inserted
        }
    }

    private func fetchFilteredBookIds(facet: String) async throws -> [String] {
        let request = try makeRequest(
            path: "/api/v1/books/ids",
            queryItems: [URLQueryItem(name: "facet", value: facet)]
        )
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError(
                "Book ID lookup for \(facet) returned HTTP \(response.statusCode)"
            )
        }
        return uniqueBookIds(
            try JSONDecoder().decode([FlexibleID].self, from: data).map(\.stringValue)
        )
    }

    func fetchShelfBooks(ids: [String]) async throws -> [Book] {
        var books: [Book] = []
        for start in stride(from: 0, to: ids.count, by: 500) {
            try Task.checkCancellation()
            let batch = ids[start..<min(start + 500, ids.count)]
            let request = try makeRequest(
                path: "/api/v1/books/batch",
                queryItems: [URLQueryItem(name: "ids", value: batch.joined(separator: ","))]
            )
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else {
                throw ProviderError.serverError("Shelf books returned HTTP \(response.statusCode)")
            }
            let records = try JSONDecoder().decode([BookloreLegacyBook].self, from: data)
            for record in records {
                guard let libraryId = record.libraryId?.stringValue else {
                    throw ProviderError.invalidResponse
                }
                books.append(mapToBook(record, fallbackLibraryId: libraryId))
            }
        }
        return books
    }

    private func fetchMagicShelfBookIds(shelfId: Int) async throws -> [String] {
        try await fetchFilteredBookIds(facet: "shelf:magic:\(shelfId)")
    }

    private func fetchShelfBookIds(shelfId: Int, expectedBookCount: Int?) async throws -> [String] {
        var membershipCandidates: [[String]] = []

        func accepts(_ ids: [String]) -> Bool {
            guard let expectedBookCount else { return true }
            return ids.count == expectedBookCount
        }

        do {
            let ids = try await fetchFilteredBookIds(facet: "shelf:\(shelfId)")
            membershipCandidates.append(ids)
            if accepts(ids) { return ids }
            AppLogger.network.warning(
                "[Booklore] Shelf \(shelfId) all-ID lookup returned \(ids.count) books; expected \(expectedBookCount ?? 0), trying direct membership"
            )
        } catch {
            AppLogger.network.warning(
                "[Booklore] Shelf \(shelfId) all-ID lookup failed; trying direct membership: \(error.localizedDescription)"
            )
        }

        do {
            let directIds = try await fetchLegacyShelfBookIds(shelfId: shelfId)
            membershipCandidates.append(directIds)
            if accepts(directIds) { return directIds }
        } catch {
            AppLogger.network.warning(
                "[Booklore] Shelf \(shelfId) direct membership failed: \(error.localizedDescription)"
            )
        }

        let returnedCounts = membershipCandidates.map(\.count)
        throw ProviderError.serverError(
            "Shelf \(shelfId) reports \(expectedBookCount.map(String.init) ?? "an unknown number of") books, but membership endpoints returned \(returnedCounts)"
        )
    }

    private func fetchLegacyShelfBookIds(shelfId: Int) async throws -> [String] {
        struct ShelfBook: Decodable { let id: FlexibleID }

        let request = try makeRequest(path: "/api/v1/shelves/\(shelfId)/books")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError(
                "Shelf \(shelfId) direct membership returned HTTP \(response.statusCode)"
            )
        }
        let books = try JSONDecoder().decode([ShelfBook].self, from: data)
        return uniqueBookIds(books.map { $0.id.stringValue })
    }

    private func uniqueBookIds(_ ids: [String]) -> [String] {
        var seenIds = Set<String>()
        return ids.filter { !$0.isEmpty && seenIds.insert($0).inserted }
    }

    func fetchSeries(libraryId: String) async throws -> [Series] {
        let books = try await fetchBooks(libraryId: libraryId)

        var seriesMap: [String: (bookIds: [String], sequences: [String: String])] = [:]
        for book in books {
            guard let info = book.seriesInfo, !info.name.isEmpty else { continue }
            var entry = seriesMap[info.name] ?? (bookIds: [], sequences: [:])
            entry.bookIds.append(book.id)
            if let seq = info.sequence {
                entry.sequences[book.id] = seq
            }
            seriesMap[info.name] = entry
        }

        return seriesMap.map { name, data in
            Series(
                id: "grimmory-series-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                name: name,
                description: nil,
                books: data.bookIds,
                bookSequences: data.sequences,
                bookCount: data.bookIds.count,
                libraryId: libraryId,
                providerId: connection.id
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] { return [] }
}
