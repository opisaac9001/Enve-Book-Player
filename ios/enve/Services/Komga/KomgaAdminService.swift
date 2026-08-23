import Foundation
import Logging

final class KomgaAdminService {
    let connection: ServerConnection

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func fetchServerInfo() async throws -> KomgaServerInfo {
        let request = try makeRequest(path: "/actuator/info")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            return KomgaServerInfo(version: nil, javaVersion: nil)
        }
        return (try? JSONDecoder().decode(KomgaServerInfo.self, from: data)) ?? KomgaServerInfo(version: nil, javaVersion: nil)
    }

    func fetchClaim() async throws -> KomgaClaim {
        let request = try makeRequest(path: "/api/v1/claim")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            return KomgaClaim(isClaimed: true)
        }
        return (try? JSONDecoder().decode(KomgaClaim.self, from: data)) ?? KomgaClaim(isClaimed: true)
    }

    func fetchCurrentUser() async throws -> KomgaUser {
        let request = try makeRequest(path: "/api/v2/users/me")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch user (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode(KomgaUser.self, from: data)
    }

    func fetchAnnouncements() async throws -> [KomgaAnnouncement] {
        let request = try makeRequest(path: "/api/v1/announcements")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { return [] }

        struct JSONFeed: Decodable {
            let items: [Item]?
            struct Item: Decodable {
                let id: String
                let title: String?
                let content_html: String?
                let date_modified: String?
                let _komga: Komga?
                struct Komga: Decodable { let read: Bool? }
            }
        }
        guard let feed = try? JSONDecoder().decode(JSONFeed.self, from: data) else { return [] }
        return (feed.items ?? []).map {
            KomgaAnnouncement(id: $0.id, title: $0.title, content: $0.content_html, date: $0.date_modified, read: $0._komga?.read)
        }
    }

    func fetchLibraries() async throws -> [KomgaLibraryDetail] {
        let request = try makeRequest(path: "/api/v1/libraries")
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch libraries (HTTP \(response.statusCode))")
        }
        return try JSONDecoder().decode([KomgaLibraryDetail].self, from: data)
    }

    func librarySeriesCount(libraryId: String) async throws -> Int {
        try await pageTotalCount(
            path: "/api/v1/series",
            queryItems: [
                URLQueryItem(name: "library_id", value: libraryId),
                URLQueryItem(name: "size", value: "1"),
            ]
        )
    }

    func libraryBookCount(libraryId: String) async throws -> Int {
        try await pageTotalCount(
            path: "/api/v1/books",
            queryItems: [
                URLQueryItem(name: "library_id", value: libraryId),
                URLQueryItem(name: "size", value: "1"),
            ]
        )
    }

    @discardableResult
    func scanLibrary(id: String, deep: Bool = false) async throws -> Bool {
        try await postEmpty(
            path: "/api/v1/libraries/\(id)/scan",
            queryItems: [
                URLQueryItem(name: "deep", value: deep ? "true" : "false")
            ]
        )
    }

    @discardableResult
    func analyzeLibrary(id: String) async throws -> Bool {
        try await postEmpty(path: "/api/v1/libraries/\(id)/analyze")
    }

    @discardableResult
    func refreshLibraryMetadata(id: String) async throws -> Bool {
        try await postEmpty(path: "/api/v1/libraries/\(id)/metadata/refresh")
    }

    @discardableResult
    func emptyLibraryTrash(id: String) async throws -> Bool {
        try await postEmpty(path: "/api/v1/libraries/\(id)/empty-trash")
    }

    func fetchRecentlyAddedSeries(limit: Int = 10) async throws -> [KomgaSeriesSummary] {
        try await fetchSeriesPage(path: "/api/v1/series/new", limit: limit)
    }

    func fetchRecentlyUpdatedSeries(limit: Int = 10) async throws -> [KomgaSeriesSummary] {
        try await fetchSeriesPage(path: "/api/v1/series/updated", limit: limit)
    }

    func fetchOnDeck(limit: Int = 10) async throws -> [KomgaBookSummary] {
        try await fetchBooksPage(path: "/api/v1/books/ondeck", limit: limit)
    }

    func fetchLatestBooks(limit: Int = 10) async throws -> [KomgaBookSummary] {
        try await fetchBooksPage(path: "/api/v1/books/latest", limit: limit)
    }

    func fetchReadLists(page: Int = 0, size: Int = 50) async throws -> [KomgaReadList] {
        let request = try makeRequest(
            path: "/api/v1/readlists",
            queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "size", value: String(size)),
            ]
        )
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { return [] }
        let result = try JSONDecoder().decode(KomgaPage<KomgaReadList>.self, from: data)
        return result.content
    }

    @discardableResult
    func createReadList(name: String, summary: String? = nil, bookIds: [String] = []) async throws -> Bool {

        let body: [String: Any] = [
            "name": name,
            "summary": summary ?? "",
            "ordered": true,
            "bookIds": bookIds,
        ]
        return try await postJSON(path: "/api/v1/readlists", body: body)
    }

    @discardableResult
    func deleteReadList(id: String) async throws -> Bool {
        try await delete(path: "/api/v1/readlists/\(id)")
    }

    func fetchCollections(page: Int = 0, size: Int = 50) async throws -> [KomgaCollectionSummary] {
        let request = try makeRequest(
            path: "/api/v1/collections",
            queryItems: [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "size", value: String(size)),
            ]
        )
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { return [] }
        let result = try JSONDecoder().decode(KomgaPage<KomgaCollectionSummary>.self, from: data)
        return result.content
    }

    @discardableResult
    func createCollection(name: String, ordered: Bool = false, seriesIds: [String] = []) async throws -> Bool {
        let body: [String: Any] = [
            "name": name,
            "ordered": ordered,
            "seriesIds": seriesIds,
        ]
        return try await postJSON(path: "/api/v1/collections", body: body)
    }

    @discardableResult
    func deleteCollection(id: String) async throws -> Bool {
        try await delete(path: "/api/v1/collections/\(id)")
    }

    func bookThumbnailURL(bookId: String) -> URL? {
        URL(string: "\(normalizedBase())/api/v1/books/\(bookId)/thumbnail")
    }

    func seriesThumbnailURL(seriesId: String) -> URL? {
        URL(string: "\(normalizedBase())/api/v1/series/\(seriesId)/thumbnail")
    }

    var imageHeaders: [String: String] { authHeaders() }

    private func fetchSeriesPage(path: String, limit: Int) async throws -> [KomgaSeriesSummary] {
        let request = try makeRequest(
            path: path,
            queryItems: [
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "size", value: String(limit)),
            ]
        )
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { return [] }
        let result = try JSONDecoder().decode(KomgaPage<KomgaSeriesSummary>.self, from: data)
        return result.content
    }

    private func fetchBooksPage(path: String, limit: Int) async throws -> [KomgaBookSummary] {
        let request = try makeRequest(
            path: path,
            queryItems: [
                URLQueryItem(name: "page", value: "0"),
                URLQueryItem(name: "size", value: String(limit)),
            ]
        )
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { return [] }
        let result = try JSONDecoder().decode(KomgaPage<KomgaBookSummary>.self, from: data)
        return result.content
    }

    private func pageTotalCount(path: String, queryItems: [URLQueryItem]) async throws -> Int {
        let request = try makeRequest(path: path, queryItems: queryItems)
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { return 0 }
        struct Page: Decodable { let totalElements: Int }
        return (try? JSONDecoder().decode(Page.self, from: data))?.totalElements ?? 0
    }

    private func postEmpty(path: String, queryItems: [URLQueryItem] = []) async throws -> Bool {
        var request = try makeRequest(path: path, queryItems: queryItems)
        request.httpMethod = "POST"
        let (_, response) = try await send(request)
        return (200...299).contains(response.statusCode)
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> Bool {
        var request = try makeRequest(path: path)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await send(request)
        return (200...299).contains(response.statusCode)
    }

    private func delete(path: String) async throws -> Bool {
        var request = try makeRequest(path: path)
        request.httpMethod = "DELETE"
        let (_, response) = try await send(request)
        return (200...299).contains(response.statusCode)
    }

    private func makeRequest(path: String, queryItems: [URLQueryItem] = [], accept: String = "application/json") throws -> URLRequest {
        guard var components = URLComponents(string: "\(normalizedBase())\(path)") else {
            throw ProviderError.invalidURL
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw ProviderError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for (key, value) in authHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        return (data, http)
    }

    private func authHeaders() -> [String: String] {
        var headers: [String: String] = [:]
        if let username = connection.username,
            let password = connection.password,
            !username.isEmpty,
            let data = "\(username):\(password)".data(using: .utf8)
        {
            headers["Authorization"] = "Basic \(data.base64EncodedString())"
        }
        return headers
    }

    private func normalizedBase() -> String {
        var str = connection.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasSuffix("/") { str.removeLast() }
        if !str.hasPrefix("http") { str = "http://\(str)" }
        return str
    }
}

struct KomgaServerInfo: Decodable {
    var version: String?
    var javaVersion: String?

    enum CodingKeys: String, CodingKey {
        case build
        case java
    }

    init(version: String?, javaVersion: String?) {
        self.version = version
        self.javaVersion = javaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let build = try? container.decodeIfPresent(BuildInfo.self, forKey: .build)
        let java = try? container.decodeIfPresent(JavaInfo.self, forKey: .java)
        self.version = build?.version
        self.javaVersion = java?.version
    }

    private struct BuildInfo: Decodable { let version: String? }
    private struct JavaInfo: Decodable { let version: String? }
}

struct KomgaClaim: Decodable {
    let isClaimed: Bool
}

struct KomgaUser: Decodable, Identifiable {
    let id: String
    let email: String
    let roles: [String]?

    var isAdmin: Bool { roles?.contains("ADMIN") ?? false }
    var isPageStreaming: Bool { roles?.contains("PAGE_STREAMING") ?? false }
    var isFileDownload: Bool { roles?.contains("FILE_DOWNLOAD") ?? false }
}

struct KomgaAnnouncement: Decodable, Identifiable {
    let id: String
    let title: String?
    let content: String?
    let date: String?
    let read: Bool?
}

struct KomgaLibraryDetail: Decodable, Identifiable {
    let id: String
    let name: String
    let root: String?
    let importComicInfoBook: Bool?
    let importComicInfoSeries: Bool?
    let importEpubBook: Bool?
    let importEpubSeries: Bool?
    let scanForceModifiedTime: Bool?
    let scanOnStartup: Bool?
    let unavailable: Bool?
    let analyzeDimensions: Bool?
}

struct KomgaSeriesSummary: Decodable, Identifiable {
    let id: String
    let libraryId: String?
    let name: String
    let booksCount: Int?
    let booksReadCount: Int?
    let booksUnreadCount: Int?
    let metadata: KomgaSeriesMetadataMini?

    var displayTitle: String { metadata?.title?.isEmpty == false ? metadata!.title! : name }
}

struct KomgaSeriesMetadataMini: Decodable {
    let title: String?
    let summary: String?
    let publisher: String?
    let status: String?
}

struct KomgaBookSummary: Decodable, Identifiable {
    let id: String
    let seriesId: String?
    let seriesTitle: String?
    let libraryId: String?
    let name: String
    let number: String?
    let metadata: KomgaBookMetadataMini?

    var displayTitle: String { metadata?.title?.isEmpty == false ? metadata!.title! : name }
}

struct KomgaBookMetadataMini: Decodable {
    let title: String?
    let summary: String?
    let number: String?
}

struct KomgaReadList: Decodable, Identifiable {
    let id: String
    let name: String
    let summary: String?
    let bookIds: [String]?
    let ordered: Bool?
    let createdDate: String?
}

struct KomgaCollectionSummary: Decodable, Identifiable {
    let id: String
    let name: String
    let ordered: Bool?
    let seriesIds: [String]?
}

private struct KomgaPage<T: Decodable>: Decodable {
    let content: [T]
    let totalElements: Int
    let totalPages: Int
    let last: Bool?
}
