// AGENT-LOCKED
import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

extension JellyfinProvider {

    private func buildAuthHeaderForLogin() -> String {
        return
            "MediaBrowser Client=\"\(jellyfinClientName)\", Device=\"\(jellyfinDeviceName)\", DeviceId=\"\(jellyfinDeviceId)\", Version=\"\(jellyfinClientVersion)\""
    }

    func authenticate(serverURL: String, username: String, password: String) async throws {
        AppLogger.network.info("[Jellyfin] ===== AUTHENTICATION STARTED =====")
        AppLogger.network.info("[Jellyfin] Server URL: \(URL(string: serverURL)?.redacted.absoluteString ?? "<invalid>")")
        AppLogger.network.info("[Jellyfin] Username: \(username)")

        let normalizedURL = normalizeServerURL(serverURL)
        AppLogger.network.info("[Jellyfin] Normalized URL: \(URL(string: normalizedURL)?.redacted.absoluteString ?? "<invalid>")")

        guard let authURL = URL(string: "\(normalizedURL)/Users/AuthenticateByName") else {
            AppLogger.network.error("[Jellyfin] Invalid server URL")
            throw ProviderError.invalidURL
        }

        AppLogger.network.info("[Jellyfin] Authenticating to: \(authURL.redacted)")

        var request = URLRequest(url: authURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(buildAuthHeaderForLogin(), forHTTPHeaderField: "Authorization")
        request.setValue(buildAuthHeaderForLogin(), forHTTPHeaderField: "X-Emby-Authorization")

        let body: [String: String] = ["Username": username, "Pw": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        AppLogger.network.info("[Jellyfin] Making network request...")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
            AppLogger.network.info("[Jellyfin] Network request completed")
        } catch {
            AppLogger.network.error("[Jellyfin] Network request failed: \(error.localizedDescription)")
            throw ProviderError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            AppLogger.network.error("[Jellyfin] Invalid response type")
            throw ProviderError.invalidResponse
        }

        AppLogger.network.info("[Jellyfin] Response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            AppLogger.network.error("[Jellyfin] Authentication failed with status: \(httpResponse.statusCode)")
            if httpResponse.statusCode == 401 {
                throw ProviderError.unauthorized
            }
            throw ProviderError.invalidResponse
        }

        struct AuthResponse: Decodable {
            let AccessToken: String
            let User: User
            struct User: Decodable {
                let Id: String
                let Name: String?
            }
        }

        let result: AuthResponse
        do {
            result = try JSONDecoder().decode(AuthResponse.self, from: data)
        } catch {
            AppLogger.network.error("[Jellyfin] Failed to decode auth response: \(error.localizedDescription)")
            throw ProviderError.decodingFailed
        }

        AppLogger.network.info("[Jellyfin] Authentication successful!")
        AppLogger.network.info("[Jellyfin] User ID: \(result.User.Id)")

        self.connection.token = result.AccessToken
        self.connection.userId = result.User.Id
        self.connection.url = normalizedURL
        self.connection.username = username

        do {
            try SecureTokenStorage.shared.saveCredentials(
                serverUrl: normalizedURL,
                username: username,
                token: result.AccessToken,
                forService: "jellyfin"
            )
            AppLogger.network.info("[Jellyfin] Credentials saved to secure storage")
        } catch {
            AppLogger.network.error("[Jellyfin] Failed to save credentials to secure storage: \(error.localizedDescription)")
        }

        AppLogger.network.info("[Jellyfin] ===== AUTHENTICATION COMPLETE =====")
    }
}
