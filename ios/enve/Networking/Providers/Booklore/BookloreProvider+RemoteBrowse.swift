import Foundation
import Logging

extension BookloreProvider {
    func remoteBookCount(libraryId: String) async throws -> Int {
        try await fetchRemoteBrowsePage(
            libraryId: libraryId,
            page: 0,
            size: 1,
            sort: .addedOn,
            descending: true,
            search: nil
        ).totalElements
    }

    func remoteBooksPage(
        libraryId: String,
        offset: Int,
        limit: Int,
        sort: GrimmoryRemoteSort,
        descending: Bool
    ) async throws -> GrimmoryRemotePage {
        guard offset >= 0, limit > 0 else { throw ProviderError.invalidResponse }
        let size = min(limit, remoteBrowsePageSize)
        let firstPage = offset / size
        let lastPage = (offset + limit - 1) / size
        let pageNumbers = Array(firstPage...lastPage)

        var pages: [BooklorePage<BookloreBookSummary>] = []
        var chunkStart = 0
        while chunkStart < pageNumbers.count {
            let chunkEnd = min(chunkStart + pageConcurrency, pageNumbers.count)
            let chunk = Array(pageNumbers[chunkStart..<chunkEnd])
            let dataByPage = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for page in chunk {
                    group.addTask {
                        (
                            page,
                            try await self.fetchRemoteBrowsePageData(
                                libraryId: libraryId,
                                page: page,
                                size: size,
                                sort: sort,
                                descending: descending,
                                search: nil
                            )
                        )
                    }
                }
                var loaded: [Int: Data] = [:]
                for try await (page, data) in group { loaded[page] = data }
                return loaded
            }

            var reachedEnd = false
            for page in chunk {
                guard let data = dataByPage[page] else { throw ProviderError.invalidResponse }
                let decoded = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
                pages.append(decoded)
                if !decoded.hasNext {
                    reachedEnd = true
                    break
                }
            }
            if reachedEnd { break }
            chunkStart = chunkEnd
        }

        let window = pages.flatMap(\.content).dropFirst(offset - firstPage * size).prefix(limit)
        let context = catalogMapperContext(libraryId: libraryId)
        return GrimmoryRemotePage(
            books: window.map { BookloreCatalogMapper.book(from: $0, context: context) },
            totalCount: pages[0].totalElements
        )
    }

    func remoteSearchBooks(libraryId: String, query: String, limit: Int) async throws -> [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }

        let page = try await fetchRemoteBrowsePage(
            libraryId: libraryId,
            page: 0,
            size: min(limit, pageSize),
            sort: .addedOn,
            descending: true,
            search: trimmed
        )

        let needle = trimmed.lowercased()
        let context = catalogMapperContext(libraryId: libraryId)
        return page.content
            .map { BookloreCatalogMapper.book(from: $0, context: context) }
            .filter { book in
                let fields: [String?] = [book.title, book.author, book.narrator, book.series]
                return fields.contains { $0?.lowercased().contains(needle) == true }
            }
    }

    private func fetchRemoteBrowsePage(
        libraryId: String,
        page: Int,
        size: Int,
        sort: GrimmoryRemoteSort,
        descending: Bool,
        search: String?
    ) async throws -> BooklorePage<BookloreBookSummary> {
        let data = try await fetchRemoteBrowsePageData(
            libraryId: libraryId,
            page: page,
            size: size,
            sort: sort,
            descending: descending,
            search: search
        )
        let result = try JSONDecoder().decode(BooklorePage<BookloreBookSummary>.self, from: data)
        rejectedContent.update(
            connection: connection,
            libraryId: libraryId,
            acceptedItemIdentifiers: Set(result.content.map { $0.id.stringValue }),
            rejectedItems: result.rejectedItems,
            fallbackScope: "browse-page-\(page)"
        )
        return result
    }

    private func fetchRemoteBrowsePageData(
        libraryId: String,
        page: Int,
        size: Int,
        sort: GrimmoryRemoteSort,
        descending: Bool,
        search: String?
    ) async throws -> Data {
        guard supportsRemoteBrowsing else { throw ProviderError.notImplemented }

        var queryItems = [
            URLQueryItem(name: "libraryId", value: libraryId),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "size", value: String(size)),
            URLQueryItem(name: "sort", value: sort.rawValue),
            URLQueryItem(name: "dir", value: descending ? "desc" : "asc"),
        ]
        if let search {
            queryItems.append(URLQueryItem(name: "search", value: search))
        }

        let request = try makeRequest(path: "/api/v1/app/books", queryItems: queryItems)
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Mobile app books returned HTTP \(response.statusCode)")
        }
        try guardJSON(data, response: response, endpoint: "/api/v1/app/books")
        return data
    }
}
