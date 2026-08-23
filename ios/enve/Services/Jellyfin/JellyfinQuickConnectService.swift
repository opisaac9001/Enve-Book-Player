import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

struct QuickConnectResult: Codable {
    let Secret: String
    let Code: String
    let Authenticated: Bool
    let DateAdded: String?
}

struct QuickConnectAuthRequest: Codable {
    let Secret: String
}

enum QuickConnectError: LocalizedError {
    case notEnabled
    case initiationFailed(Int)
    case pollFailed(String)
    case authenticationFailed(Int)
    case timeout
    case cancelled
    case invalidResponse
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            return "Quick Connect is not enabled on this server. Ask your server admin to enable it."
        case .initiationFailed(let code):
            return "Failed to initiate Quick Connect (HTTP \(code))"
        case .pollFailed(let message):
            return "Quick Connect polling failed: \(message)"
        case .authenticationFailed(let code):
            return "Quick Connect authentication failed (HTTP \(code))"
        case .timeout:
            return "Quick Connect code expired. Please try again."
        case .cancelled:
            return "Quick Connect was cancelled."
        case .invalidResponse:
            return "Invalid response from server."
        case .invalidURL:
            return "Invalid server URL."
        }
    }
}

struct JellyfinQuickConnectAuthResult {
    let token: String
    let userId: String
    let userName: String?
}

final class JellyfinQuickConnectService {
    static let shared = JellyfinQuickConnectService()
    private init() {}

    private let maxPollAttempts = 150
    private let pollInterval: TimeInterval = 2.0

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
        let raw = UIDevice.current.name
        return raw.replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
        #else
        return "Enve Client"
        #endif
    }

    private func buildAuthHeader(token: String? = nil) -> String {
        var header =
            "MediaBrowser Client=\"\(clientName)\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
        if let token {
            header += ", Token=\"\(token)\""
        }
        return header
    }

    private func applyCustomHeaders(_ customHeaders: [String: String], to request: inout URLRequest) {
        for (key, value) in customHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }

    func isQuickConnectEnabled(serverURL: String, customHeaders: [String: String] = [:]) async throws -> Bool {
        let normalized = normalizeURL(serverURL)
        guard let url = URL(string: "\(normalized)/QuickConnect/Enabled") else {
            throw QuickConnectError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        applyCustomHeaders(customHeaders, to: &request)
        let auth = buildAuthHeader()
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
            httpResponse.statusCode == 200
        else {
            return false
        }

        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return str.lowercased() == "true"
        }
        return false
    }

    func initiateQuickConnect(serverURL: String, customHeaders: [String: String] = [:]) async throws -> QuickConnectResult {
        let normalized = normalizeURL(serverURL)
        guard let url = URL(string: "\(normalized)/QuickConnect/Initiate") else {
            throw QuickConnectError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        applyCustomHeaders(customHeaders, to: &request)
        let auth = buildAuthHeader()
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuickConnectError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            AppLogger.network.error("Initiate failed: HTTP \(httpResponse.statusCode)")
            throw QuickConnectError.initiationFailed(httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(QuickConnectResult.self, from: data)
        AppLogger.network.info("Initiated - Code: \(result.Code)")
        return result
    }

    func pollForAuthentication(
        secret: String,
        serverURL: String,
        customHeaders: [String: String] = [:],
        cancellationCheck: @escaping () -> Bool = { false }
    ) async throws -> String {
        let normalized = normalizeURL(serverURL)

        for attempt in 1...maxPollAttempts {
            if cancellationCheck() {
                throw QuickConnectError.cancelled
            }

            guard var components = URLComponents(string: "\(normalized)/QuickConnect/Connect") else {
                throw QuickConnectError.invalidURL
            }
            components.queryItems = [URLQueryItem(name: "secret", value: secret)]

            guard let url = components.url else {
                throw QuickConnectError.invalidURL
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            applyCustomHeaders(customHeaders, to: &request)
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw QuickConnectError.invalidResponse
                }

                if httpResponse.statusCode == 200 {
                    let result = try JSONDecoder().decode(QuickConnectResult.self, from: data)
                    if result.Authenticated {
                        AppLogger.network.info("Code approved on attempt \(attempt)")
                        return secret
                    }
                } else if httpResponse.statusCode == 404 {
                    throw QuickConnectError.timeout
                }
            } catch let error as QuickConnectError {
                throw error
            } catch {
                AppLogger.network.error("Poll attempt \(attempt) failed: \(error.localizedDescription)")
            }

            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        throw QuickConnectError.timeout
    }

    func authenticateWithQuickConnect(
        secret: String,
        serverURL: String,
        customHeaders: [String: String] = [:]
    ) async throws -> JellyfinQuickConnectAuthResult {
        let normalized = normalizeURL(serverURL)
        guard let url = URL(string: "\(normalized)/Users/AuthenticateWithQuickConnect") else {
            throw QuickConnectError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        applyCustomHeaders(customHeaders, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let auth = buildAuthHeader()
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")

        let body = QuickConnectAuthRequest(Secret: secret)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw QuickConnectError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            AppLogger.network.error("Auth failed: HTTP \(httpResponse.statusCode)")
            throw QuickConnectError.authenticationFailed(httpResponse.statusCode)
        }

        struct AuthResponse: Decodable {
            let AccessToken: String
            let User: UserInfo
            struct UserInfo: Decodable {
                let Id: String
                let Name: String?
            }
        }

        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)
        AppLogger.network.info("Authentication successful - User: \(authResponse.User.Name ?? "unknown")")

        return JellyfinQuickConnectAuthResult(
            token: authResponse.AccessToken,
            userId: authResponse.User.Id,
            userName: authResponse.User.Name
        )
    }

    private func normalizeURL(_ input: String) -> String {
        var url = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if !url.lowercased().hasPrefix("http://") && !url.lowercased().hasPrefix("https://") {
            let isLocal =
                url.hasPrefix("192.") || url.hasPrefix("10.") || url.hasPrefix("172.") || url.hasPrefix("localhost")
                || url.hasPrefix("127.")
            url = (isLocal ? "http://" : "https://") + url
        }
        return url
    }
}
