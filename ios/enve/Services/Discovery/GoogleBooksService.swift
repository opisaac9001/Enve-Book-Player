import Foundation
import Logging

private struct GoogleBooksSearchResponse: Codable {
    let items: [GoogleBooksVolume]?
}

private struct GoogleBooksErrorResponse: Codable {
    let error: GoogleBooksErrorPayload?
}

private struct GoogleBooksErrorPayload: Codable {
    let code: Int?
    let message: String?
    let errors: [GoogleBooksErrorEntry]?
}

private struct GoogleBooksErrorEntry: Codable {
    let reason: String?
    let message: String?
}

private struct GoogleBooksVolume: Codable {
    let id: String
    let volumeInfo: GoogleBooksVolumeInfo
}

private struct GoogleBooksVolumeInfo: Codable {
    let title: String?
    let subtitle: String?
    let authors: [String]?
    let publisher: String?
    let publishedDate: String?
    let description: String?
    let pageCount: Int?
    let categories: [String]?
    let averageRating: Double?
    let ratingsCount: Int?
    let imageLinks: GoogleBooksImageLinks?
    let language: String?
    let industryIdentifiers: [GoogleBooksIndustryIdentifier]?
}

private struct GoogleBooksIndustryIdentifier: Codable {
    let type: String?
    let identifier: String?
}

final class GoogleBooksService: @unchecked Sendable {
    static let shared = GoogleBooksService()
    private init() {}

    private let baseURL = URL(string: "https://www.googleapis.com/books/v1/volumes")!
    private let session = URLSession.shared
    private let stateLock = NSLock()
    private var lastRequestAt: Date = .distantPast
    private var rateLimitedUntil: Date?
    private var rateLimitWasKeyed: Bool?
    private var consecutiveRateLimits = 0
    private var searchCache: [String: [GoogleBooksMetadataLayer]] = [:]
    private var volumeCache: [String: GoogleBooksMetadataLayer] = [:]
    private var inFlightSearches: [String: Task<[GoogleBooksMetadataLayer], Error>] = [:]
    private var inFlightVolumes: [String: Task<GoogleBooksMetadataLayer, Error>] = [:]

    enum SearchError: LocalizedError {
        case rateLimited
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .rateLimited:
                return "Google Books rate-limited the request."
            case .httpStatus(let code):
                return "Google Books search failed (\(code))."
            }
        }
    }

    private let transientStatusCodes: Set<Int> = [500, 502, 503, 504]
    private let retryableNetworkCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorCallIsActive,
        NSURLErrorDataNotAllowed,
    ]

    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    func search(query: String, author: String?, isbn: String?, limit: Int = 10) async throws -> [GoogleBooksMetadataLayer] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty || !(isbn?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            return []
        }

        let searchTerms = buildSearchTermCandidates(query: trimmedQuery, author: author, isbn: isbn)
        let resolvedLimit = min(limit, 10)
        let cacheKey = "q=\(searchTerms.joined(separator: "|").lowercased())|limit=\(resolvedLimit)|apiKey=\(hasAPIKey ? "keyed" : "anon")"

        if let cached = withState({ searchCache[cacheKey] }) {
            return Array(cached.prefix(resolvedLimit))
        }

        if let task = withState({ inFlightSearches[cacheKey] }) {
            let results = try await task.value
            return Array(results.prefix(resolvedLimit))
        }

        let task = Task<[GoogleBooksMetadataLayer], Error> {
            try await self.performSearch(searchTerms: searchTerms, limit: resolvedLimit, cacheKey: cacheKey)
        }
        withState { inFlightSearches[cacheKey] = task }

        defer { withState { inFlightSearches[cacheKey] = nil } }

        let results = try await task.value
        return Array(results.prefix(resolvedLimit))
    }

    func getVolume(id: String) async throws -> GoogleBooksMetadataLayer {
        if let cached = withState({ volumeCache[id] }) {
            return cached
        }

        if let task = withState({ inFlightVolumes[id] }) {
            return try await task.value
        }

        let task = Task<GoogleBooksMetadataLayer, Error> {
            try await self.performGetVolume(id: id)
        }
        withState { inFlightVolumes[id] = task }

        defer { withState { inFlightVolumes[id] = nil } }

        return try await task.value
    }

    private var hasAPIKey: Bool {
        if let apiKey = SettingsManager.shared.googleBooksApiKey?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return !apiKey.isEmpty
        }
        return false
    }

    private func performSearch(searchTerms: [String], limit: Int, cacheKey: String) async throws -> [GoogleBooksMetadataLayer] {
        let maxAttempts = hasAPIKey ? 2 : 3
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            do {
                let results = try await performSearchAttempts(searchTerms: searchTerms, limit: limit)
                withState { searchCache[cacheKey] = results }
                return results
            } catch {
                lastError = error
                guard shouldRetry(error: error, attempt: attempt, maxAttempts: maxAttempts) else {
                    throw error
                }

                let backoff = min(pow(2.0, Double(attempt)) * 0.75, 3.0)
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }

        throw lastError ?? SearchError.httpStatus(503)
    }

    private func performSearchAttempts(searchTerms: [String], limit: Int) async throws -> [GoogleBooksMetadataLayer] {
        var results: [GoogleBooksMetadataLayer] = []
        var seen = Set<String>()

        for terms in searchTerms {
            let hits = try await performSearchAttempt(searchTerms: terms, limit: max(limit, 10))
            for hit in hits {
                let key = dedupeKey(for: hit)
                guard seen.insert(key).inserted else { continue }
                results.append(hit)
            }
            if results.count >= limit { break }
        }

        return Array(results.prefix(limit))
    }

    private func performSearchAttempt(searchTerms: String, limit: Int) async throws -> [GoogleBooksMetadataLayer] {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true)!
        components.queryItems = [
            URLQueryItem(name: "q", value: searchTerms),
            URLQueryItem(name: "printType", value: "books"),
            URLQueryItem(name: "projection", value: "full"),
            URLQueryItem(name: "orderBy", value: "relevance"),
            URLQueryItem(name: "maxResults", value: String(limit)),
        ]

        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await sendRequest(to: url)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        try handleStatus(http.statusCode, data: data)

        let decoded = try JSONDecoder().decode(GoogleBooksSearchResponse.self, from: data)
        return (decoded.items ?? []).map(Self.toMetadataLayer)
    }

    private func performGetVolume(id: String) async throws -> GoogleBooksMetadataLayer {
        let maxAttempts = hasAPIKey ? 2 : 3
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            do {
                let result = try await performGetVolumeAttempt(id: id)
                withState { volumeCache[id] = result }
                return result
            } catch {
                lastError = error
                guard shouldRetry(error: error, attempt: attempt, maxAttempts: maxAttempts) else {
                    throw error
                }

                let backoff = min(pow(2.0, Double(attempt)) * 0.75, 3.0)
                try await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }

        throw lastError ?? SearchError.httpStatus(503)
    }

    private func performGetVolumeAttempt(id: String) async throws -> GoogleBooksMetadataLayer {
        var components = URLComponents(url: baseURL.appendingPathComponent(id), resolvingAgainstBaseURL: true)!
        components.queryItems = [URLQueryItem(name: "projection", value: "full")]

        guard let url = components.url else { throw URLError(.badURL) }

        let (data, response) = try await sendRequest(to: url)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        try handleStatus(http.statusCode, data: data)

        let volume = try JSONDecoder().decode(GoogleBooksVolume.self, from: data)
        return Self.toMetadataLayer(volume)
    }

    private func sendRequest(to url: URL) async throws -> (Data, URLResponse) {
        try await waitForPermit()
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let apiKey = SettingsManager.shared.googleBooksApiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        AppLogger.network.debug(
            "[GoogleBooks] Request endpointDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: url.path)) keyed=\(self.hasAPIKey)"
        )
        let result = try await session.data(for: request)
        if let http = result.1 as? HTTPURLResponse {
            AppLogger.network.info("[GoogleBooks] Response \(http.statusCode) bytes=\(result.0.count)")
        }
        withState { lastRequestAt = Date() }
        return result
    }

    private func waitForPermit() async throws {
        let requestIsKeyed = hasAPIKey
        if let blockedUntil = withState({ rateLimitWasKeyed == requestIsKeyed ? rateLimitedUntil : nil }) {
            let wait = blockedUntil.timeIntervalSinceNow
            if wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            withState {
                rateLimitedUntil = nil
                rateLimitWasKeyed = nil
            }
        }

        let minimumSpacing: TimeInterval = hasAPIKey ? 0.35 : 1.25
        let lastRequest = withState { lastRequestAt }
        let elapsed = Date().timeIntervalSince(lastRequest)
        if elapsed < minimumSpacing {
            try await Task.sleep(nanoseconds: UInt64((minimumSpacing - elapsed) * 1_000_000_000))
        }
    }

    private func handleStatus(_ statusCode: Int, data: Data) throws {
        guard (200...299).contains(statusCode) else {
            if isRateLimitResponse(statusCode: statusCode, data: data) {
                let backoff = withState { () -> TimeInterval in
                    consecutiveRateLimits += 1
                    let backoff = min(pow(2.0, Double(max(0, consecutiveRateLimits - 1))) * 4.0, 60.0)
                    rateLimitedUntil = Date().addingTimeInterval(backoff)
                    rateLimitWasKeyed = hasAPIKey
                    return backoff
                }
                _ = backoff
                throw SearchError.rateLimited
            }

            if transientStatusCodes.contains(statusCode) {
                throw SearchError.httpStatus(statusCode)
            }
            throw SearchError.httpStatus(statusCode)
        }

        withState {
            consecutiveRateLimits = 0
            rateLimitedUntil = nil
            rateLimitWasKeyed = nil
        }
    }

    private func isRateLimitResponse(statusCode: Int, data: Data) -> Bool {
        if statusCode == 429 {
            return true
        }

        guard statusCode == 403 else {
            return false
        }

        if let payload = try? JSONDecoder().decode(GoogleBooksErrorResponse.self, from: data) {
            let reasons = payload.error?.errors?.compactMap { $0.reason?.lowercased() } ?? []
            let message = payload.error?.message?.lowercased() ?? ""
            if reasons.contains(where: { $0.contains("ratelimit") || $0.contains("quota") }) {
                return true
            }
            if message.contains("quota") || message.contains("rate limit") || message.contains("user rate limit") {
                return true
            }
        }

        return false
    }

    private func shouldRetry(error: Error, attempt: Int, maxAttempts: Int) -> Bool {
        guard attempt + 1 < maxAttempts else { return false }

        if let searchError = error as? SearchError {
            switch searchError {
            case .rateLimited:
                return true
            case .httpStatus(let code):
                return transientStatusCodes.contains(code)
            }
        }

        if let urlError = error as? URLError {
            return retryableNetworkCodes.contains(urlError.errorCode)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return retryableNetworkCodes.contains(nsError.code)
        }

        return false
    }

    private func buildSearchTermCandidates(query: String, author: String?, isbn: String?) -> [String] {
        var candidates: [String] = []

        if let isbn = isbn?.trimmingCharacters(in: .whitespacesAndNewlines), !isbn.isEmpty {
            candidates.append("isbn:\(isbn)")
        }

        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAuthor = author?
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !cleanQuery.isEmpty, let cleanAuthor, !cleanAuthor.isEmpty {
            candidates.append("\(cleanQuery) \(cleanAuthor)")
            if let lastName = cleanAuthor.split(separator: " ").last {
                candidates.append("\(cleanQuery) \(lastName)")
                candidates.append("\(cleanQuery) inauthor:\(lastName)")
            }
        }

        if !cleanQuery.isEmpty {
            candidates.append(cleanQuery)
        }

        return Array(NSOrderedSet(array: candidates).compactMap { $0 as? String })
    }

    private func dedupeKey(for layer: GoogleBooksMetadataLayer) -> String {
        if let isbn = layer.isbn?.trimmingCharacters(in: .whitespacesAndNewlines), !isbn.isEmpty {
            return "isbn:\(isbn.lowercased())"
        }
        let title = layer.title?.lowercased() ?? ""
        let authors = (layer.authors ?? []).joined(separator: ",").lowercased()
        return "\(title)|\(authors)"
    }

    private nonisolated static func toMetadataLayer(_ volume: GoogleBooksVolume) -> GoogleBooksMetadataLayer {
        let info = volume.volumeInfo
        let isbn =
            info.industryIdentifiers?.first(where: { $0.type == "ISBN_13" })?.identifier
            ?? info.industryIdentifiers?.first(where: { $0.type == "ISBN_10" })?.identifier
            ?? info.industryIdentifiers?.first?.identifier

        return GoogleBooksMetadataLayer(
            isbn: isbn,
            title: info.title,
            subtitle: info.subtitle,
            authors: info.authors,
            publisher: info.publisher,
            publishedDate: info.publishedDate,
            description: info.description,
            pageCount: info.pageCount,
            categories: info.categories,
            averageRating: info.averageRating,
            ratingsCount: info.ratingsCount,
            imageLinks: info.imageLinks,
            language: info.language
        )
    }
}
