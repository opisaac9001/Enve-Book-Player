import Foundation

enum ReadwiseError: LocalizedError {
    case notConnected
    case invalidToken
    case secureStorage
    case invalidResponse
    case rateLimited(String?)
    case server(Int)
    case textTooLong(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Connect Readwise before sending highlights."
        case .invalidToken: "Readwise didn't accept this token. Check your token and Readwise account access."
        case .secureStorage: "The Readwise token couldn't be saved securely. Please try again."
        case .invalidResponse: "Readwise's response couldn't be confirmed. Try sending again; matching highlights won't be duplicated."
        case .rateLimited(let seconds): seconds.map { "Readwise is busy. Try again in \($0) seconds." } ?? "Readwise is busy. Wait a moment, then try again."
        case .server(let status): "Readwise couldn't complete the request (HTTP \(status)). Try again later."
        case .textTooLong(let field): "\(field) exceeds Readwise's limit. Export this book's notes as a file instead."
        }
    }
}

@MainActor
final class ReadwiseClient {
    struct Highlight: Encodable, Sendable {
        let text: String
        let title: String
        let author: String?
        let note: String
        let location: Int
        let highlightedAt: String
        let sourceType = "enve_book_player"
        let category = "books"
        let locationType = "order"

        enum CodingKeys: String, CodingKey {
            case text, title, author, note, location, category
            case highlightedAt = "highlighted_at"
            case sourceType = "source_type"
            case locationType = "location_type"
        }
    }

    private struct CreatedBook: Decodable {
        let id: Int
        let modified_highlights: [Int]?
    }

    private struct HighlightPage: Decodable {
        struct Entry: Decodable { let id: Int; let text: String }
        let results: [Entry]
        let next: String?
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
        nonisolated func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private let session: URLSession
    private let minimumRequestInterval: Duration
    private var lastRequestAt: ContinuousClock.Instant?
    private var lastListRequestAt: ContinuousClock.Instant?

    init(session: URLSession? = nil, minimumRequestInterval: Duration = .milliseconds(260)) {
        self.minimumRequestInterval = minimumRequestInterval
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
        }
    }

    func validate(token: String) async throws {
        _ = try await request(path: "auth/", method: "GET", token: token, expectedStatus: 204)
    }

    func create(_ highlight: Highlight, token: String) async throws -> Int {
        struct Body: Encodable { let highlights: [Highlight] }
        let body = try JSONEncoder().encode(Body(highlights: [highlight]))
        let data = try await request(path: "highlights/", method: "POST", token: token, body: body)
        guard let books = try? JSONDecoder().decode([CreatedBook].self, from: data), let book = books.first else {
            throw ReadwiseError.invalidResponse
        }
        if let ids = book.modified_highlights, ids.count == 1, let id = ids.first { return id }

        // A retry after a lost response can match a highlight created before this device recorded its ID.
        var page = 1
        while true {
            let data = try await request(path: "highlights/?book_id=\(book.id)&page_size=1000&page=\(page)", method: "GET", token: token)
            guard let result = try? JSONDecoder().decode(HighlightPage.self, from: data) else { throw ReadwiseError.invalidResponse }
            if let existing = result.results.first(where: { $0.text == highlight.text }) {
                try await update(id: existing.id, highlight: highlight, token: token)
                return existing.id
            }
            guard result.next != nil, !result.results.isEmpty else { throw ReadwiseError.invalidResponse }
            page += 1
        }
    }

    func update(id: Int, highlight: Highlight, token: String) async throws {
        struct Body: Encodable { let text: String; let note: String; let location: Int }
        let body = try JSONEncoder().encode(Body(text: highlight.text, note: highlight.note, location: highlight.location))
        _ = try await request(path: "highlights/\(id)/", method: "PATCH", token: token, body: body)
    }

    func retire() { session.invalidateAndCancel() }

    private func request(path: String, method: String, token: String, body: Data? = nil, expectedStatus: Int = 200) async throws -> Data {
        try Task.checkCancellation()
        let clock = ContinuousClock()
        if let lastRequestAt { try await clock.sleep(until: lastRequestAt.advanced(by: minimumRequestInterval)) }
        let isListRequest = method == "GET" && path.hasPrefix("highlights/?")
        if isListRequest, let lastListRequestAt { try await clock.sleep(until: lastListRequestAt.advanced(by: .milliseconds(3100))) }
        try Task.checkCancellation()
        lastRequestAt = clock.now
        if isListRequest { lastListRequestAt = clock.now }
        var request = URLRequest(url: URL(string: "https://readwise.io/api/v2/" + path)!)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Token " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw ReadwiseError.invalidResponse }
        switch response.statusCode {
        case expectedStatus: return data
        case 401, 403: throw ReadwiseError.invalidToken
        case 429:
            let delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).map { String(max(0, $0)) }
            throw ReadwiseError.rateLimited(delay)
        default: throw ReadwiseError.server(response.statusCode)
        }
    }
}
