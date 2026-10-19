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
        var lastError: Error = ProviderError.invalidResponse

        for path in ["/api/v1/app/shelves", "/api/v1/shelves"] {
            do {
                let request = try makeRequest(path: path)
                let (data, response) = try await performAuthorizedRequest(request)
                guard response.statusCode == 200 else {
                    lastError = ProviderError.serverError("Shelf discovery returned HTTP \(response.statusCode)")
                    continue
                }
                do {
                    return try JSONDecoder().decode([GrimmoryShelfSummary].self, from: data)
                } catch {
                    lastError = error
                }
            } catch {
                lastError = error
            }
        }

        throw lastError
    }

    private func fetchMagicShelfSummaries() async throws -> [GrimmoryMagicShelfSummary] {
        var lastError: Error = ProviderError.invalidResponse

        for path in ["/api/v1/app/shelves/magic", "/api/magic-shelves"] {
            do {
                let request = try makeRequest(path: path)
                let (data, response) = try await performAuthorizedRequest(request)
                guard response.statusCode == 200 else {
                    lastError = ProviderError.serverError("Magic Shelf discovery returned HTTP \(response.statusCode)")
                    continue
                }
                do {
                    return try JSONDecoder().decode([GrimmoryMagicShelfSummary].self, from: data)
                } catch {
                    lastError = error
                }
            } catch {
                lastError = error
            }
        }

        throw lastError
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

    private func fetchFilteredBookIds(filterName: String, filterId: Int) async throws -> [String] {
        let request = try makeRequest(
            path: "/api/v1/app/books/ids",
            queryItems: [URLQueryItem(name: filterName, value: String(filterId))]
        )
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError(
                "Book ID lookup for \(filterName) \(filterId) returned HTTP \(response.statusCode)"
            )
        }
        return uniqueBookIds(
            try JSONDecoder().decode([FlexibleID].self, from: data).map(\.stringValue)
        )
    }

    private func fetchMagicShelfBookIds(shelfId: Int) async throws -> [String] {
        do {
            return try await fetchFilteredBookIds(filterName: "magicShelfId", filterId: shelfId)
        } catch {
            AppLogger.network.warning(
                "[Booklore] Magic Shelf \(shelfId) all-ID lookup failed; trying paginated membership: \(error.localizedDescription)"
            )
        }

        return try await fetchAllLegacyMagicShelfBookIds(shelfId: shelfId)
    }

    private func fetchAllLegacyMagicShelfBookIds(shelfId: Int) async throws -> [String] {
        var page = 0
        let pageSize = 500
        var allIds: [String] = []
        var seenIds = Set<String>()

        while true {
            let result = try await fetchLegacyMagicShelfBookIds(
                shelfId: shelfId,
                page: page,
                size: pageSize
            )
            let newIds = result.ids.filter { seenIds.insert($0).inserted }
            allIds.append(contentsOf: newIds)
            if !result.hasNext { break }
            if newIds.isEmpty {
                throw ProviderError.serverError(
                    "Magic Shelf \(shelfId) returned a repeated page before membership completed"
                )
            }
            page += 1
            if page > 1000 {
                throw ProviderError.serverError("Magic Shelf \(shelfId) membership exceeded 1000 pages")
            }
        }

        return allIds
    }

    private func fetchLegacyMagicShelfBookIds(
        shelfId: Int,
        page: Int,
        size: Int
    ) async throws -> (ids: [String], hasNext: Bool) {
        struct AppBook: Decodable {
            let id: FlexibleID
        }
        struct PageResponse: Decodable {
            let content: [AppBook]
            let page: Int?
            let totalPages: Int?
            let hasNext: Bool?
        }

        let request = try makeRequest(
            path: "/api/v1/app/shelves/magic/\(shelfId)/books",
            queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "size", value: String(size)),
            ]
        )
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError(
                "Magic Shelf \(shelfId) membership returned HTTP \(response.statusCode)"
            )
        }
        let result = try JSONDecoder().decode(PageResponse.self, from: data)
        let hasNext = result.hasNext ?? ((result.page ?? page) + 1 < (result.totalPages ?? 1))
        return (result.content.map(\.id.stringValue), hasNext)
    }

    private func fetchShelfBookIds(shelfId: Int, expectedBookCount: Int?) async throws -> [String] {
        var membershipCandidates: [[String]] = []

        func accepts(_ ids: [String]) -> Bool {
            guard let expectedBookCount else { return true }
            return ids.count == expectedBookCount
        }

        do {
            let ids = try await fetchFilteredBookIds(filterName: "shelfId", filterId: shelfId)
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
            AppLogger.network.warning(
                "[Booklore] Shelf \(shelfId) direct membership returned \(directIds.count) books; expected \(expectedBookCount ?? 0), trying paginated app books"
            )
        } catch {
            AppLogger.network.warning(
                "[Booklore] Shelf \(shelfId) direct membership failed; trying paginated app books: \(error.localizedDescription)"
            )
        }

        do {
            let paginatedIds = try await fetchPaginatedShelfBookIds(shelfId: shelfId)
            membershipCandidates.append(paginatedIds)
            if accepts(paginatedIds) { return paginatedIds }
        } catch {
            AppLogger.network.warning(
                "[Booklore] Shelf \(shelfId) paginated membership failed: \(error.localizedDescription)"
            )
        }

        let returnedCounts = membershipCandidates.map(\.count)
        throw ProviderError.serverError(
            "Shelf \(shelfId) reports \(expectedBookCount.map(String.init) ?? "an unknown number of") books, but membership endpoints returned \(returnedCounts)"
        )
    }

    private func fetchPaginatedShelfBookIds(shelfId: Int) async throws -> [String] {
        struct ShelfBookPage: Decodable {
            let content: [ShelfBookEntry]
            let hasNext: Bool?
            struct ShelfBookEntry: Decodable { let id: FlexibleID }
        }

        var page = 0
        let pageSize = 500
        var ids: [String] = []

        while true {
            let request = try makeRequest(
                path: "/api/v1/app/books",
                queryItems: [
                    URLQueryItem(name: "shelfId", value: String(shelfId)),
                    URLQueryItem(name: "page", value: String(page)),
                    URLQueryItem(name: "size", value: String(pageSize)),
                ]
            )
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else {
                throw ProviderError.serverError(
                    "Shelf \(shelfId) app membership returned HTTP \(response.statusCode) on page \(page)"
                )
            }
            let result = try JSONDecoder().decode(ShelfBookPage.self, from: data)
            ids.append(contentsOf: result.content.map { $0.id.stringValue })
            if result.hasNext != true { break }
            page += 1
            if page > 1000 {
                throw ProviderError.serverError("Shelf \(shelfId) membership exceeded 1000 pages")
            }
        }
        return uniqueBookIds(ids)
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
