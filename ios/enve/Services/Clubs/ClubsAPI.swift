#if os(iOS)
import Foundation

struct ClubsResponseError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

struct ClubsAPI {
    static var configuredURL: URL? {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["ENVE_CLUBS_SERVICE_URL"],
           let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1" || url.host == "localhost" {
            return url
        }
        #endif
        guard let value = Bundle.main.object(forInfoDictionaryKey: "EnveClubsServiceURL") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    static func inviteURL(code: String) -> URL? {
        var url = URLComponents()
        if configuredURL?.scheme == "https" {
            url.scheme = "https"
            url.host = "envemedia.com"
            url.path = "/books/clubs/join/"
            url.fragment = "code=\(code)"
            return url.url
        }
        url.scheme = EnveBookLink.scheme
        url.host = "club"
        url.path = "/join"
        url.queryItems = [URLQueryItem(name: "code", value: code)]
        return url.url
    }

    static func inviteCode(from url: URL) -> String? {
        let isAppLink = url.scheme == EnveBookLink.scheme && url.host == "club" && url.path == "/join"
        guard isAppLink,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count == 1, items[0].name == "code",
              let value = items[0].value, value.utf8.count == 10,
              value.utf8.allSatisfy({ (65...90).contains($0) && $0 != 73 && $0 != 79 || (50...57).contains($0) })
        else { return nil }
        return value
    }

    struct ID: Decodable { let id: String }
    struct OK: Decodable { let ok: Bool }
    struct Recovery: Decodable { let recoveryKey: String }
    private struct Failure: Decodable { let error: String }

    let baseURL: URL
    private let session: URLSession
    private let downloadSession: URLSession

    init(baseURL: URL) {
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: ClubsNoRedirects(), delegateQueue: nil)
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7_200
        downloadSession = URLSession(configuration: configuration, delegate: ClubsNoRedirects(), delegateQueue: nil)
    }

    func request<Value: Decodable>(
        _ path: String,
        method: String = "GET",
        token: String?,
        body: (any Encodable)? = nil,
        query: [URLQueryItem] = []
    ) async throws -> Value {
        var request = makeRequest(path, method: method, token: token, query: query)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .custom { date, encoder in
                var value = encoder.singleValueContainer()
                try value.encode(Int64((date.timeIntervalSince1970 * 1000).rounded()))
            }
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard (200...299).contains(response.statusCode) else {
            let failure = try? decoder.decode(Failure.self, from: data)
            throw ClubsResponseError(status: response.statusCode, message: failure?.error ?? "Clubs is temporarily unavailable.")
        }
        return try decoder.decode(Value.self, from: data)
    }

    func download(
        _ path: String,
        token: String,
        file: ClubHostedCopy.File,
        destination: URL
    ) async throws {
        var request = makeRequest(path, method: "GET", token: token)
        request.setValue(file.contentType, forHTTPHeaderField: "Accept")
        let (temporaryFile, response) = try await downloadSession.download(for: request)
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: temporaryFile) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 else {
            let failure = try? FileHandle(forReadingFrom: temporaryFile)
            defer { try? failure?.close() }
            let data = try? failure?.read(upToCount: 16_384)
            let message = data.flatMap { try? JSONDecoder().decode(Failure.self, from: $0).error }
            throw ClubsResponseError(status: response.statusCode, message: message ?? "The club copy could not be downloaded.")
        }
        let size = try fileManager.attributesOfItem(atPath: temporaryFile.path)[.size] as? NSNumber
        guard size?.int64Value == file.bytes,
              response.mimeType?.caseInsensitiveCompare(file.contentType) == .orderedSame else {
            throw ClubsResponseError(status: 502, message: "The club copy did not match its file listing. Ask the host to check the shared copy.")
        }
        try fileManager.moveItem(at: temporaryFile, to: destination)
    }

    func invalidate() {
        session.invalidateAndCancel()
        downloadSession.invalidateAndCancel()
    }

    private func makeRequest(
        _ path: String,
        method: String,
        token: String?,
        query: [URLQueryItem] = []
    ) -> URLRequest {
        var url = baseURL.appendingPathComponent("v1").appendingPathComponent(path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }
}

private final class ClubsNoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
#endif
