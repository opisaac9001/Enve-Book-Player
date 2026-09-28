import Foundation

/// A progression service Enve has adopted for one publication.
nonisolated struct OPDSProgressionEndpoint: Codable, Equatable, Sendable {
    let url: URL
    /// The `properties.authenticate` hint, used only to name the sign-in document when the service answers 401.
    let authenticateURL: URL?

    init(url: URL, authenticateURL: URL? = nil) {
        self.url = url
        self.authenticateURL = authenticateURL
    }
}

nonisolated enum OPDSProgressionError: LocalizedError, Equatable {
    case unauthorized(authenticateURL: URL?)
    /// `409`: the service already holds a more recent progression point.
    case staleProgression(OPDSProblemDetails?)
    case refused(OPDSProblemDetails)
    case malformedPayload
    case unexpectedStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unauthorized(let authenticateURL):
            guard let authenticateURL else {
                return "The progression service rejected the stored credentials."
            }
            return "The progression service requires a sign-in at \(authenticateURL.absoluteString)."
        case .staleProgression(let details):
            return details?.message ?? "A more recent progression point is already available."
        case .refused(let details):
            return details.message
        case .malformedPayload:
            return "The progression service did not answer with a progression document."
        case .unexpectedStatus(let status):
            return "The progression service returned HTTP \(status)."
        }
    }
}

/// Pure request/response rules for the OPDS Progression 1.0 draft.
enum OPDSProgressionTransport {
    static let mediaType = "application/opds-progression+json"
    static let linkRelation = "http://opds-spec.org/progression"

    enum Fetched: Equatable, Sendable {
        case progression(OPDSProgressionDocument)
        /// A `200` with an empty payload: the service has never been told a position for this publication.
        case notRecorded
    }

    /// Require the relation and media type; off-origin services are allowed but receive no feed credentials.
    static func endpoint(in links: [OPDSLink], baseURL: URL) -> OPDSProgressionEndpoint? {
        for link in links {
            guard !link.templated,
                link.hasRel(linkRelation),
                normalizedMediaType(link.type) == mediaType,
                let url = requestableURL(link.href, baseURL: baseURL)
            else { continue }

            // The hint is a link property, so it resolves against the document that carried the link.
            return OPDSProgressionEndpoint(
                url: url,
                authenticateURL: requestableURL(link.properties?.authenticate?.href, baseURL: baseURL)
            )
        }
        return nil
    }

    private static func requestableURL(_ href: String?, baseURL: URL) -> URL? {
        href.flatMap { OPDSURL.resolve($0, baseURL: baseURL) }
    }

    static func request(_ method: String, endpoint: OPDSProgressionEndpoint) -> URLRequest {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(mediaType, forHTTPHeaderField: "Accept")
        return request
    }

    static func readFetch(
        status: Int,
        contentType: String?,
        data: Data,
        endpoint: OPDSProgressionEndpoint
    ) throws -> Fetched {
        guard status == 200 else { throw failure(status: status, data: data, endpoint: endpoint) }
        // A service with nothing to report answers with no body, and then has no payload to describe.
        guard !isEmpty(data) else { return .notRecorded }
        try requireProgressionContentType(contentType)
        return .progression(try decode(data))
    }

    /// Both 200 and 201 PUT responses must contain a Progression Document.
    static func readSubmit(
        status: Int,
        contentType: String?,
        data: Data,
        endpoint: OPDSProgressionEndpoint
    ) throws -> OPDSProgressionDocument {
        guard status == 200 || status == 201 else {
            throw failure(status: status, data: data, endpoint: endpoint)
        }
        try requireProgressionContentType(contentType)
        return try decode(data)
    }

    static func encode(_ document: OPDSProgressionDocument) throws -> Data {
        try JSONEncoder().encode(document)
    }

    private static func failure(status: Int, data: Data, endpoint: OPDSProgressionEndpoint) -> OPDSProgressionError {
        if status == 401 { return .unauthorized(authenticateURL: endpoint.authenticateURL) }
        let details = try? JSONDecoder().decode(OPDSProblemDetails.self, from: data)
        if status == 409 { return .staleProgression(details) }
        if let details { return .refused(details) }
        return .unexpectedStatus(status)
    }

    /// Reject declared non-progression media types; validate the body when no type is supplied.
    private static func requireProgressionContentType(_ value: String?) throws {
        guard let declared = normalizedMediaType(value), !declared.isEmpty else { return }
        guard declared == mediaType else { throw OPDSProgressionError.malformedPayload }
    }

    private static func decode(_ data: Data) throws -> OPDSProgressionDocument {
        guard let document = try? JSONDecoder().decode(OPDSProgressionDocument.self, from: data) else {
            throw OPDSProgressionError.malformedPayload
        }
        return document
    }

    private static func isEmpty(_ data: Data) -> Bool {
        data.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    private static func normalizedMediaType(_ value: String?) -> String? {
        guard let value else { return nil }
        return value.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}
