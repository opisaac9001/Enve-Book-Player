import Foundation

/// An OPDS Authentication 1.0 flow and its endpoints.
struct OPDSAuthenticationFlow: Equatable, Sendable, Identifiable {
    /// Retain unsupported flows so the sign-in sheet can explain the server requirements.
    enum Kind: Equatable, Sendable {
        /// HTTP Basic, and Digest, which `URLSession` answers from the same login and password.
        case httpCredentials
        /// The local flow uses the password exchange without grant_type.
        case local
        case oauthPassword
        case oauthImplicit
        case unsupported

        init(type: String) {
            switch type.lowercased() {
            case "http://opds-spec.org/auth/basic", "http://opds-spec.org/auth/digest": self = .httpCredentials
            case "http://opds-spec.org/auth/local": self = .local
            case "http://opds-spec.org/auth/oauth/password": self = .oauthPassword
            case "http://opds-spec.org/auth/oauth/implicit": self = .oauthImplicit
            default: self = .unsupported
            }
        }
    }

    let kind: Kind
    let type: String
    let summary: String?
    let loginLabel: String
    let passwordLabel: String
    /// Where the credentials are posted, or the page the reader signs in on for the implicit flow.
    let authenticateURL: URL?
    let refreshURL: URL?

    var id: String { type }

    /// A flow needing an endpoint it did not name cannot be run whatever its type says.
    var isSupported: Bool {
        switch kind {
        case .httpCredentials: true
        case .local, .oauthPassword, .oauthImplicit: authenticateURL != nil
        case .unsupported: false
        }
    }

    /// Whether the reader is asked for a login and a password rather than sent to a browser.
    var usesCredentialForm: Bool {
        kind == .httpCredentials || kind == .local || kind == .oauthPassword
    }

    var displayName: String {
        switch kind {
        case .httpCredentials: "Username and password"
        case .local: "Library account"
        case .oauthPassword: "Sign in with your account"
        case .oauthImplicit: "Sign in through your browser"
        case .unsupported: type
        }
    }
}

/// OPDS Authentication 1.0 document, discovered through a 401 response or a feed link.
struct OPDSAuthenticationDocument: Equatable, Sendable, Identifiable {
    static let mediaType = "application/opds-authentication+json"
    /// The media type the specification shipped with before it was registered. Servers still send it.
    static let legacyMediaType = "application/vnd.opds.authentication.v1.0+json"

    let identifier: String?
    let title: String
    let summary: String?
    let logoURL: URL?
    let helpURL: URL?
    let registerURL: URL?
    let startURL: URL?
    let flows: [OPDSAuthenticationFlow]
    /// Persist the document URL so later HTML 401 responses can still offer sign-in.
    var documentURL: URL?

    /// Use the title as sheet identity when the document omits its id.
    var id: String { identifier ?? title }

    var supportedFlows: [OPDSAuthenticationFlow] { flows.filter(\.isSupported) }

    /// The same document, with the URL it was fetched from standing in when it named none itself.
    func resolvingDocumentURL(_ url: URL) -> OPDSAuthenticationDocument {
        guard documentURL == nil else { return self }
        var resolved = self
        resolved.documentURL = url
        return resolved
    }

    static func isAuthenticationMediaType(_ value: String?) -> Bool {
        guard let declared = value?.split(separator: ";").first?
            .trimmingCharacters(in: .whitespaces).lowercased()
        else { return false }
        return declared == mediaType || declared == legacyMediaType
    }

    /// Returns nil for non-authentication payloads, including HTML sign-in pages.
    static func decode(_ data: Data, baseURL: URL) -> OPDSAuthenticationDocument? {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), !wire.authentication.isEmpty else {
            return nil
        }

        func url(forRel rel: String, in links: [OPDSLink]) -> URL? {
            links
                .first { $0.hasRel(rel) && !$0.templated }?
                .href
                .flatMap { OPDSURL.resolve($0, baseURL: baseURL) }
        }

        let flows = wire.authentication.map { object in
            OPDSAuthenticationFlow(
                kind: OPDSAuthenticationFlow.Kind(type: object.type),
                type: object.type,
                summary: object.description,
                loginLabel: object.labels?.login ?? "Username",
                passwordLabel: object.labels?.password ?? "Password",
                authenticateURL: url(forRel: "authenticate", in: object.links),
                refreshURL: url(forRel: "refresh", in: object.links)
            )
        }

        return OPDSAuthenticationDocument(
            identifier: wire.id,
            title: wire.title ?? "Sign in",
            summary: wire.description,
            logoURL: url(forRel: "logo", in: wire.links),
            helpURL: url(forRel: "help", in: wire.links),
            registerURL: url(forRel: "register", in: wire.links),
            startURL: url(forRel: "start", in: wire.links),
            flows: flows,
            documentURL: url(forRel: "self", in: wire.links)
        )
    }

    /// Extract the authentication-document href from WWW-Authenticate.
    static func documentURL(
        inChallenge header: String?,
        baseURL: URL
    ) -> URL? {
        guard let header else { return nil }
        for parameter in challengeParameters(in: header) where parameter.name == "href" {
            if let url = OPDSURL.resolve(parameter.value, baseURL: baseURL) { return url }
        }
        return nil
    }

    /// Parse challenge parameters without splitting commas inside quoted values.
    static func challengeParameters(in header: String) -> [(name: String, value: String)] {
        var parameters: [(name: String, value: String)] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false

        func takeCurrent() {
            defer { current = "" }
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { return }
            // The scheme sits in front of the first parameter of each challenge: `Bearer realm="…"`.
            guard let name = trimmed[trimmed.startIndex..<equals]
                .split(separator: " ").last?.lowercased(), !name.isEmpty
            else { return }

            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            guard !value.isEmpty else { return }
            parameters.append((name, value))
        }

        for character in header {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }
            switch character {
            case "\\" where isQuoted:
                current.append(character)
                isEscaped = true
            case "\"":
                isQuoted.toggle()
                current.append(character)
            case "," where !isQuoted:
                takeCurrent()
            default:
                current.append(character)
            }
        }
        takeCurrent()
        return parameters
    }

    private struct Wire: Decodable {
        let id: String?
        let title: String?
        let description: String?
        let links: [OPDSLink]
        let authentication: [Object]

        struct Object: Decodable {
            let type: String
            let description: String?
            let labels: Labels?
            let links: [OPDSLink]

            struct Labels: Decodable {
                let login: String?
                let password: String?
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                type = try container.decode(String.self, forKey: .type)
                description = try container.decodeIfPresent(String.self, forKey: .description)
                labels = try? container.decode(Labels.self, forKey: .labels)
                links = (try? container.decode([OPDSLink].self, forKey: .links)) ?? []
            }

            private enum CodingKeys: String, CodingKey { case type, description, labels, links }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            title = try container.decodeIfPresent(String.self, forKey: .title)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            links = (try? container.decode([OPDSLink].self, forKey: .links)) ?? []
            authentication = (try? container.decode([Object].self, forKey: .authentication)) ?? []
        }

        private enum CodingKeys: String, CodingKey { case id, title, description, links, authentication }
    }
}
