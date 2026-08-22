import Combine
import Foundation
import Logging

private struct DriveFileList: Codable {
    let files: [DriveFile]
    let nextPageToken: String?
}

private struct DriveFile: Codable {
    let id: String
    let name: String
    let mimeType: String
    let size: String?
    let modifiedTime: String?
    let parents: [String]?

    var isFolder: Bool {
        return mimeType == "application/vnd.google-apps.folder"
    }
}

enum GoogleDriveError: LocalizedError {
    case notAuthenticated
    case invalidResponse
    case networkError(Error)
    case rateLimitExceeded
    case quotaExceeded
    case fileNotFound
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with Google Drive"
        case .invalidResponse:
            return "Invalid response from Google Drive"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .rateLimitExceeded:
            return "Rate limit exceeded. Please try again later."
        case .quotaExceeded:
            return "Quota exceeded"
        case .fileNotFound:
            return "File not found"
        case .permissionDenied:
            return "Permission denied"
        }
    }
}

@MainActor
final class GoogleDriveProvider: BookSourceProvider {
    let id = "google-drive"
    let displayName = "Google Drive"
    let iconName = "internaldrive"
    let capabilities: SourceCapabilities = [.streaming, .folderBrowsing, .search]

    @Published private(set) var authenticationState: AuthenticationState = .notAuthenticated

    private let oauthManager = OAuthManager.shared
    private let tokenStorage = SecureTokenStorage.shared
    private let session = URLSession.shared
    private var currentToken: OAuthToken?

    private let baseURL = "https://www.googleapis.com/drive/v3"

    init() {
        Task {
            await loadSavedToken()
        }
    }

    func authenticate() async throws {
        authenticationState = .authenticating

        do {
            let config = OAuthConfig.googleDrive()
            let token = try await oauthManager.authorize(config: config)
            currentToken = token
            try tokenStorage.saveToken(token, forProvider: id)
            authenticationState = .authenticated
        } catch {
            authenticationState = .authenticationFailed(error.localizedDescription)
            throw error
        }
    }

    func refreshAuthentication() async throws {
        guard let token = currentToken ?? (try? tokenStorage.loadToken(forProvider: id)) else {
            throw GoogleDriveError.notAuthenticated
        }

        guard let refreshToken = token.refreshToken else {
            throw OAuthError.missingRefreshToken
        }

        do {
            let config = OAuthConfig.googleDrive()
            let newToken = try await oauthManager.refreshToken(refreshToken: refreshToken, config: config)
            currentToken = newToken
            try tokenStorage.saveToken(newToken, forProvider: id)
            authenticationState = .authenticated
        } catch {
            authenticationState = .tokenExpired
            throw error
        }
    }

    func signOut() async throws {
        currentToken = nil
        try tokenStorage.deleteToken(forProvider: id)
        authenticationState = .notAuthenticated
    }

    private func loadSavedToken() async {
        do {
            if let token = try tokenStorage.loadToken(forProvider: id) {
                if token.isExpired {
                    authenticationState = .tokenExpired
                } else {
                    currentToken = token
                    authenticationState = .authenticated
                }
            }
        } catch {
            AppLogger.network.error("Failed to load Google Drive token: \(error)")
        }
    }

    func listRoot() async throws -> [RemoteItem] {
        return try await listFiles(query: "'root' in parents and trashed = false")
    }

    func listFolder(_ itemId: String) async throws -> [RemoteItem] {
        return try await listFiles(query: "'\(itemId)' in parents and trashed = false")
    }

    func search(_ query: String) async throws -> [RemoteItem] {
        let searchQuery =
            "name contains '\(query)' and (mimeType contains 'audio/' or mimeType = 'application/vnd.google-apps.folder') and trashed = false"
        return try await listFiles(query: searchQuery)
    }

    private func listFiles(query: String, pageToken: String? = nil) async throws -> [RemoteItem] {
        try await ensureValidToken()

        guard var components = URLComponents(string: "\(baseURL)/files") else {
            throw NSError(domain: "GoogleDriveProvider", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"])
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType,size,modifiedTime,parents),nextPageToken"),
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "orderBy", value: "folder,name"),
        ]

        if let pageToken = pageToken {
            components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
        }

        guard let requestURL = components.url else {
            throw URLError(.badURL)
        }

        guard let token = currentToken?.accessToken else {
            throw URLError(.userAuthenticationRequired)
        }

        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)

        try handleResponse(response, data: data)

        let fileList = try JSONDecoder().decode(DriveFileList.self, from: data)
        var items = fileList.files.map { convertToRemoteItem($0) }

        if let nextPageToken = fileList.nextPageToken {
            let nextPage = try await listFiles(query: query, pageToken: nextPageToken)
            items.append(contentsOf: nextPage)
        }

        return items.filter { $0.isFolder || $0.isAudioFile }
    }

    func resolveFile(_ item: RemoteItem) async throws -> ResolvedFile {
        try await ensureValidToken()

        guard let streamURL = URL(string: "\(baseURL)/files/\(item.id)?alt=media") else {
            throw URLError(.badURL)
        }

        return ResolvedFile(
            localURL: nil,
            streamURL: streamURL,
            expiresAt: currentToken?.expiresAt,
            requiresAuthHeader: true,
            authHeaderValue: "Bearer \(currentToken?.accessToken ?? "")",
            contentLength: item.size
        )
    }

    func getMetadata(_ item: RemoteItem) async throws -> SourceBookMetadata? {
        return SourceBookMetadata(
            title: item.name,
            author: nil,
            narrator: nil,
            description: nil,
            coverURL: nil,
            duration: nil,
            chapters: nil,
            series: nil,
            seriesNumber: nil,
            publishedYear: nil,
            genres: nil,
            publisher: nil,
            isbn: nil,
            asin: nil
        )
    }

    private func ensureValidToken() async throws {
        guard let token = currentToken else {
            throw GoogleDriveError.notAuthenticated
        }

        if token.isExpired {
            try await refreshAuthentication()
        }
    }

    private func convertToRemoteItem(_ file: DriveFile) -> RemoteItem {
        let size = file.size.flatMap { Int64($0) }
        let modifiedDate = file.modifiedTime.flatMap { ISO8601DateFormatter().date(from: $0) }

        return RemoteItem(
            id: file.id,
            name: file.name,
            isFolder: file.isFolder,
            size: size,
            mimeType: file.mimeType,
            modifiedDate: modifiedDate,
            pathHint: nil,
            parentId: file.parents?.first
        )
    }

    private func handleResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GoogleDriveError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401:
            authenticationState = .tokenExpired
            throw GoogleDriveError.notAuthenticated
        case 403:
            if let errorMessage = String(data: data, encoding: .utf8),
                errorMessage.contains("rateLimitExceeded")
            {
                throw GoogleDriveError.rateLimitExceeded
            } else {
                throw GoogleDriveError.permissionDenied
            }
        case 404:
            throw GoogleDriveError.fileNotFound
        case 429:
            throw GoogleDriveError.rateLimitExceeded
        default:
            throw GoogleDriveError.invalidResponse
        }
    }
}
