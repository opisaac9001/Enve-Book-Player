import Foundation
import Logging

nonisolated struct BookBridgeMapping: Decodable, Sendable {
    let documentHash: String
    let percentage: Double?
    let timestamp: String?
    let linkedABSId: String?
    let linkedBookTitle: String?

    enum CodingKeys: String, CodingKey {
        case documentHash = "document_hash"
        case percentage
        case timestamp
        case linkedABSId = "linked_abs_id"
        case linkedBookTitle = "linked_book_title"
    }
}

nonisolated private struct BookBridgeMappingsResponse: Decodable {
    let documents: [BookBridgeMapping]
    let total: Int
    let linked: Int
    let unlinked: Int
}

enum BookBridgeError: LocalizedError {
    case missingURL
    case invalidURL(String)
    case http(Int, String)
    case decode(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .missingURL: return "BookBridge URL is not configured."
        case .invalidURL(let s): return "Invalid BookBridge URL: \(s)"
        case .http(let code, let body): return "BookBridge returned \(code): \(body)"
        case .decode(let err): return "Couldn't read BookBridge response: \(err.localizedDescription)"
        case .transport(let err): return "Network error: \(err.localizedDescription)"
        }
    }
}

actor BookBridgeClient {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 15
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: cfg)
        }
    }

    func healthCheck(baseURL: URL) async -> Bool {
        let url = baseURL.appendingPathComponent("api/health")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await session.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func fetchMappings(baseURL: URL) async throws -> [BookBridgeMapping] {
        let url = baseURL.appendingPathComponent("api/kosync-documents")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw BookBridgeError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw BookBridgeError.http(-1, "Bad response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BookBridgeError.http(http.statusCode, body)
        }

        do {
            let decoded = try JSONDecoder().decode(BookBridgeMappingsResponse.self, from: data)
            return decoded.documents
        } catch {
            throw BookBridgeError.decode(error)
        }
    }
}
