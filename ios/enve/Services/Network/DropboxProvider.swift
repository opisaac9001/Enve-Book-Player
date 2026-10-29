import Foundation
import Observation

@MainActor
@Observable
final class DropboxProvider: BookSourceProvider {
    let id = "dropbox"
    let displayName = "Dropbox"
    let iconName = "shippingbox.fill"
    let capabilities: SourceCapabilities = [.folderBrowsing, .search]
    private(set) var authenticationState: AuthenticationState = .notAuthenticated

    private let oauthManager: OAuthManager
    private let tokenStorage: SecureTokenStorage
    private let session: URLSession
    private var currentToken: OAuthToken?

    init(
        oauthManager: OAuthManager = .shared,
        tokenStorage: SecureTokenStorage = .shared,
        session: URLSession = .shared
    ) {
        self.oauthManager = oauthManager
        self.tokenStorage = tokenStorage
        self.session = session
        do {
            currentToken = try tokenStorage.loadToken(forProvider: id)
            if let currentToken {
                authenticationState = currentToken.isExpired ? .tokenExpired : .authenticated
            }
        } catch {
            authenticationState = .authenticationFailed("Could not restore your Dropbox connection. Please sign in again.")
        }
    }

    func authenticate() async throws {
        authenticationState = .authenticating
        do {
            let token = try await oauthManager.authorize(config: .dropbox())
            try tokenStorage.saveToken(token, forProvider: id)
            currentToken = token
            authenticationState = .authenticated
        } catch {
            authenticationState = .authenticationFailed(error.localizedDescription)
            throw error
        }
    }

    func refreshAuthentication() async throws {
        guard let refreshToken = currentToken?.refreshToken else { throw OAuthError.missingRefreshToken }
        do {
            let token = try await oauthManager.refreshToken(refreshToken: refreshToken, config: .dropbox())
            try tokenStorage.saveToken(token, forProvider: id)
            currentToken = token
            authenticationState = .authenticated
        } catch {
            authenticationState = .tokenExpired
            throw error
        }
    }

    func signOut() async throws {
        try tokenStorage.deleteToken(forProvider: id)
        currentToken = nil
        authenticationState = .notAuthenticated
    }

    func listRoot() async throws -> [RemoteItem] {
        try await listFolder("")
    }

    func listFolder(_ itemId: String) async throws -> [RemoteItem] {
        var page: FolderPage = try await rpc("files/list_folder", body: ["path": itemId, "recursive": false])
        var entries = page.entries
        while page.hasMore {
            try Task.checkCancellation()
            page = try await rpc("files/list_folder/continue", body: ["cursor": page.cursor])
            entries += page.entries
        }
        return entries.compactMap(\.remoteItem).filter { $0.isFolder || $0.isSupportedBookFile }
            .sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func search(_ query: String) async throws -> [RemoteItem] {
        var page: SearchPage = try await rpc("files/search_v2", body: ["query": query, "options": ["filename_only": true]])
        var matches = page.matches
        while page.hasMore {
            try Task.checkCancellation()
            guard let cursor = page.cursor else { throw DropboxError.invalidResponse }
            page = try await rpc("files/search/continue_v2", body: ["cursor": cursor])
            matches += page.matches
        }
        return matches.compactMap { $0.metadata.metadata.remoteItem }.filter { $0.isFolder || $0.isSupportedBookFile }
    }

    func resolveFile(_ item: RemoteItem) async throws -> ResolvedFile {
        guard item.isSupportedBookFile else { throw DropboxError.unsupportedFile }
        let result: TemporaryLink = try await rpc("files/get_temporary_link", body: ["path": item.id])
        guard let url = URL(string: result.link), url.scheme == "https",
            let host = url.host?.lowercased(),
            host == "dropboxusercontent.com" || host.hasSuffix(".dropboxusercontent.com")
                || host == "dropbox.com" || host.hasSuffix(".dropbox.com")
        else { throw DropboxError.invalidResponse }
        return ResolvedFile(
            localURL: nil, streamURL: url, expiresAt: Date().addingTimeInterval(4 * 3600),
            requiresAuthHeader: false, authHeaderValue: nil, contentLength: item.size
        )
    }

    func getMetadata(_ item: RemoteItem) async throws -> SourceBookMetadata? {
        .fromFilename(item.name)
    }

    private func rpc<T: Decodable>(_ path: String, body: [String: Any], retry: Bool = true) async throws -> T {
        guard let currentToken else { throw DropboxError.notAuthenticated }
        if currentToken.expiresAt.map({ $0.timeIntervalSinceNow <= 60 }) == true { try await refreshAuthentication() }
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let accessToken = self.currentToken?.accessToken else { throw DropboxError.notAuthenticated }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DropboxError.invalidResponse }
        if response.statusCode == 401 {
            authenticationState = .tokenExpired
            if retry, self.currentToken?.refreshToken != nil {
                try await refreshAuthentication()
                return try await rpc(path, body: body, retry: false)
            }
            throw DropboxError.notAuthenticated
        }
        switch response.statusCode {
        case 200...299: return try JSONDecoder().decode(T.self, from: data)
        case 403: throw DropboxError.permissionDenied
        case 409: throw DropboxError.unavailable
        case 429: throw DropboxError.rateLimited
        default: throw DropboxError.requestFailed(response.statusCode)
        }
    }

    private struct Entry: Decodable {
        let tag: String
        let id: String?
        let name: String
        let pathDisplay: String?
        let size: Int64?
        let serverModified: String?

        enum CodingKeys: String, CodingKey {
            case tag = ".tag", id, name, size
            case pathDisplay = "path_display"
            case serverModified = "server_modified"
        }

        var remoteItem: RemoteItem? {
            guard tag == "file" || tag == "folder", let id else { return nil }
            return RemoteItem(
                id: id, name: name, isFolder: tag == "folder", size: size, mimeType: nil,
                modifiedDate: serverModified.flatMap { ISO8601DateFormatter().date(from: $0) },
                pathHint: pathDisplay, parentId: nil
            )
        }
    }

    private struct FolderPage: Decodable {
        let entries: [Entry]
        let cursor: String
        let hasMore: Bool
        enum CodingKeys: String, CodingKey { case entries, cursor; case hasMore = "has_more" }
    }

    private struct SearchPage: Decodable {
        struct Match: Decodable {
            struct Metadata: Decodable { let metadata: Entry }
            let metadata: Metadata
        }
        let matches: [Match]
        let cursor: String?
        let hasMore: Bool
        enum CodingKeys: String, CodingKey { case matches, cursor; case hasMore = "has_more" }
    }

    private struct TemporaryLink: Decodable { let link: String }
}

private enum DropboxError: LocalizedError {
    case notAuthenticated, invalidResponse, unsupportedFile, permissionDenied, unavailable, rateLimited
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Sign in to Dropbox again."
        case .invalidResponse: "Dropbox returned an invalid response."
        case .unsupportedFile: "Choose a supported audiobook or ebook file."
        case .permissionDenied: "Dropbox did not allow access to this file. Reconnect your account to review permissions."
        case .unavailable: "This Dropbox file or folder is no longer available. Refresh and try again."
        case .rateLimited: "Dropbox is receiving too many requests. Wait a moment and try again."
        case .requestFailed(let status): "Dropbox could not complete the request (HTTP \(status)). Try again."
        }
    }
}
