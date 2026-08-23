import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

class JellyfinService: @unchecked Sendable {
    static let shared = JellyfinService()
    private init() {}

    private var clientName: String { "Enve" }
    private var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var deviceId: String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        return UUID().uuidString
        #endif
    }
    private var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        #else
        return "Enve Client"
        #endif
    }

    private func buildAuthHeader(token: String?) -> String {
        var header =
            "MediaBrowser Client=\"\(clientName)\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
        if let token = token {
            header += ", Token=\"\(token)\""
        }
        return header
    }

    func validateToken(backend: BackendConfig) async throws -> Bool {
        AppLogger.network.info("[JellyfinService] ===== TOKEN VALIDATION STARTED =====")
        guard let token = backend.token, !token.isEmpty else {
            AppLogger.network.info("[JellyfinService] No token provided")
            return false
        }

        let normalizedURL = normalizeServerURL(backend.url)
        AppLogger.network.info("[JellyfinService] Normalized URL: \(URL(string: normalizedURL)?.redacted.absoluteString ?? "<invalid>")")

        guard let url = URL(string: "\(normalizedURL)/Users/Me") else {
            AppLogger.network.error("[JellyfinService] Invalid URL for validation")
            return false
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        AppLogger.network.info("[JellyfinService] Validating token at: \(url.redacted)")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                AppLogger.network.error("[JellyfinService] Invalid response type")
                return false
            }

            AppLogger.network.info("[JellyfinService] Validation response status: \(httpResponse.statusCode)")

            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let userId = json["Id"] as? String
                {
                    AppLogger.network.info("[JellyfinService] Token valid, User ID: \(userId)")
                }
                return true
            } else if httpResponse.statusCode == 401 {
                AppLogger.network.info("[JellyfinService] Token is unauthorized (401)")
                return false
            }

            return httpResponse.statusCode == 200
        } catch {
            AppLogger.network.error("[JellyfinService] Validation failed with error: \(error.localizedDescription)")
            return false
        }
    }

    func getLibraries(backend: BackendConfig) async throws -> [LibraryMetadata] {
        guard let token = backend.token, !token.isEmpty else {
            AppLogger.network.info("No token provided for getLibraries")
            throw ProviderError.unauthorized
        }

        let normalizedURL = normalizeServerURL(backend.url)

        let userId = try await getUserId(serverUrl: normalizedURL, token: token)

        guard let url = URL(string: "\(normalizedURL)/UserViews?userId=\(userId)") else {
            AppLogger.network.error("Invalid URL for libraries")
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        AppLogger.network.info("Fetching libraries from: \(url.redacted)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }

        AppLogger.network.info("Libraries response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            throw ProviderError.invalidResponse
        }

        struct ViewsResponse: Decodable {
            let Items: [ViewItem]
        }

        struct ViewItem: Decodable {
            let Id: String
            let Name: String
            let CollectionType: String?
        }

        let viewsResponse = try JSONDecoder().decode(ViewsResponse.self, from: data)

        AppLogger.network.info("Found \(viewsResponse.Items.count) libraries/views")

        var libraries: [LibraryMetadata] = []
        for item in viewsResponse.Items {
            let libraryType: LibraryType
            switch item.CollectionType?.lowercased() {
            case "books", "audiobooks":
                libraryType = .audiobooks
            case "movies":
                libraryType = .movies
            case "tvshows":
                libraryType = .tvshows
            case "music":
                libraryType = .music
            default:
                libraryType = .mixed
            }

            var itemCount = 0
            do {

                if let countUrl = URL(string: "\(normalizedURL)/Items?userId=\(userId)&parentId=\(item.Id)&limit=0") {
                    var countRequest = URLRequest(url: countUrl)
                    let auth = buildAuthHeader(token: token)
                    countRequest.setValue(auth, forHTTPHeaderField: "Authorization")
                    countRequest.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
                    countRequest.setValue(token, forHTTPHeaderField: "X-Emby-Token")
                    countRequest.setValue("application/json", forHTTPHeaderField: "Accept")

                    let (countData, _) = try await URLSession.shared.data(for: countRequest)

                    struct ItemsResponse: Decodable {
                        let TotalRecordCount: Int?
                    }

                    if let itemsResponse = try? JSONDecoder().decode(ItemsResponse.self, from: countData),
                        let total = itemsResponse.TotalRecordCount
                    {
                        itemCount = total
                    }
                }
            } catch {
                AppLogger.network.error("Failed to fetch item count for \(item.Name): \(error)")
            }

            AppLogger.network.info("Library: \(item.Name) (ID: \(item.Id), Type: \(item.CollectionType ?? "unknown"), Items: \(itemCount))")

            libraries.append(
                LibraryMetadata(
                    id: item.Id,
                    name: item.Name,
                    type: libraryType,
                    itemCount: itemCount,
                    audioBookCount: libraryType == .audiobooks ? itemCount : 0,
                    collectionType: item.CollectionType
                )
            )
        }

        return libraries
    }

    private func getUserId(serverUrl: String, token: String) async throws -> String {
        guard let url = URL(string: "\(serverUrl)/Users/Me") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderError.unauthorized
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let userId = json["Id"] as? String
        else {
            throw ProviderError.decodingFailed
        }

        return userId
    }

    private func normalizeServerURL(_ input: String) -> String {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if trimmed.isEmpty { return input }

        if !trimmed.lowercased().hasPrefix("http") {
            if trimmed.contains(":8920") {
                trimmed = "https://\(trimmed)"
            } else if trimmed.contains(":8096") {
                trimmed = "http://\(trimmed)"
            } else {
                let lower = trimmed.lowercased()
                let isLocal =
                    lower.hasPrefix("localhost")
                    || lower.hasPrefix("127.")
                    || lower.range(of: "^\\d{1,3}(\\.\\d{1,3}){3}", options: .regularExpression) != nil
                trimmed = (isLocal ? "http://" : "https://") + trimmed
            }
        }

        return trimmed
    }

    func getSystemInfo(backend: BackendConfig) async throws -> JellyfinSystemInfo {
        guard let token = backend.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        let normalizedURL = normalizeServerURL(backend.url)
        guard let url = URL(string: "\(normalizedURL)/System/Info") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderError.unauthorized
        }

        return try JSONDecoder().decode(JellyfinSystemInfo.self, from: data)
    }

    func getUsers(backend: BackendConfig) async throws -> [JellyfinAdminUser] {
        guard let token = backend.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        let normalizedURL = normalizeServerURL(backend.url)
        guard let url = URL(string: "\(normalizedURL)/Users") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderError.unauthorized
        }

        return try JSONDecoder().decode([JellyfinAdminUser].self, from: data)
    }

    func getCurrentUserInfo(backend: BackendConfig) async throws -> JellyfinAdminUser {
        guard let token = backend.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        let normalizedURL = normalizeServerURL(backend.url)
        guard let url = URL(string: "\(normalizedURL)/Users/Me") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderError.unauthorized
        }

        return try JSONDecoder().decode(JellyfinAdminUser.self, from: data)
    }

    func createUser(name: String, password: String?, backend: BackendConfig) async throws -> JellyfinAdminUser {
        guard let token = backend.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        let normalizedURL = normalizeServerURL(backend.url)
        guard let url = URL(string: "\(normalizedURL)/Users/New") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let createRequest = JellyfinUserCreateRequest(name: name, password: password)
        request.httpBody = try JSONEncoder().encode(createRequest)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.unknown
        }

        return try JSONDecoder().decode(JellyfinAdminUser.self, from: data)
    }

    func deleteUser(userId: String, backend: BackendConfig) async throws {
        guard let token = backend.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        let normalizedURL = normalizeServerURL(backend.url)
        guard let url = URL(string: "\(normalizedURL)/Users/\(userId)") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.timeoutInterval = 30
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.unknown
        }
    }

    func updateUserPolicy(userId: String, policy: JellyfinPolicyUpdateRequest, backend: BackendConfig) async throws {
        guard let token = backend.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        let normalizedURL = normalizeServerURL(backend.url)
        guard let url = URL(string: "\(normalizedURL)/Users/\(userId)/Policy") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        request.httpBody = try JSONEncoder().encode(policy)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.unknown
        }
    }

    func getPlugins(backend: BackendConfig) async throws -> [JellyfinPlugin] {
        guard let token = backend.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        let normalizedURL = normalizeServerURL(backend.url)
        guard let url = URL(string: "\(normalizedURL)/Plugins") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderError.unauthorized
        }

        return try JSONDecoder().decode([JellyfinPlugin].self, from: data)
    }

    func getScheduledTasks(backend: BackendConfig) async throws -> [JellyfinScheduledTask] {
        guard let token = backend.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        let normalizedURL = normalizeServerURL(backend.url)
        guard let url = URL(string: "\(normalizedURL)/ScheduledTasks") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderError.unauthorized
        }

        return try JSONDecoder().decode([JellyfinScheduledTask].self, from: data)
    }

    func runScheduledTask(taskId: String, backend: BackendConfig) async throws {
        guard let token = backend.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        let normalizedURL = normalizeServerURL(backend.url)
        guard let url = URL(string: "\(normalizedURL)/ScheduledTasks/Running/\(taskId)") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.unknown
        }
    }

    func getActiveSessions(backend: BackendConfig) async throws -> [JellyfinActiveSession] {
        guard let token = backend.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        let normalizedURL = normalizeServerURL(backend.url)
        guard let url = URL(string: "\(normalizedURL)/Sessions") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw ProviderError.unauthorized
        }

        return try JSONDecoder().decode([JellyfinActiveSession].self, from: data)
    }

    func refreshLibrary(libraryId: String, backend: BackendConfig) async throws {
        guard let token = backend.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        let normalizedURL = normalizeServerURL(backend.url)

        guard let url = URL(string: "\(normalizedURL)/Items/\(libraryId)/Refresh?metadataRefreshMode=Default&imageRefreshMode=Default")
        else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.unknown
        }
    }

    func restartServer(backend: BackendConfig) async throws {
        guard let token = backend.token, !token.isEmpty else {
            throw ProviderError.unauthorized
        }

        let normalizedURL = normalizeServerURL(backend.url)
        guard let url = URL(string: "\(normalizedURL)/System/Restart") else {
            throw ProviderError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        let auth = buildAuthHeader(token: token)
        request.setValue(auth, forHTTPHeaderField: "Authorization")
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw ProviderError.unknown
        }
    }
}
