import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw PlexError.networkError(
                NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorTimedOut,
                    userInfo: [NSLocalizedDescriptionKey: "Request timed out after \(seconds) seconds"]
                )
            )
        }

        guard let result = try await group.next() else {
            throw PlexError.networkError(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: "Request timed out"])
            )
        }
        group.cancelAll()
        return result
    }
}

enum PlexError: LocalizedError {
    case invalidURL
    case invalidToken
    case serverUnreachable
    case networkError(Error)
    case decodingError(Error)
    case pinExpired
    case authenticationFailed
    case unknownStatusCode(Int)
    case httpError(code: Int, body: String?)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid Plex URL"
        case .invalidToken:
            return "Invalid Plex authentication token"
        case .serverUnreachable:
            return "Cannot reach Plex server"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .pinExpired:
            return "Plex PIN has expired"
        case .authenticationFailed:
            return "Plex authentication failed"
        case .unknownStatusCode(let code):
            return "Unexpected HTTP status code: \(code)"
        case .httpError(let code, let body):
            if let body, !body.isEmpty {
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                let snippet = trimmed.count > 400 ? String(trimmed.prefix(400)) + "…" : trimmed
                return "Plex returned HTTP \(code): \(snippet)"
            }
            return "Plex returned HTTP \(code)"
        }
    }
}

public class PlexService: @unchecked Sendable {
    let session: URLSession
    let baseURL = "https://plex.tv"
    private let clientIdentifier: String
    private let product: String
    private let appVersion: String
    private let deviceName: String
    private let deviceModel: String
    private let platformVersion: String
    private let storageService: StorageService

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    public init(session: URLSession? = nil, storageService: StorageService = StorageService()) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = true

        self.session = session ?? URLSession(configuration: configuration)
        self.storageService = storageService

        self.product =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Enve"

        self.clientIdentifier = PlexAuthStore.shared.loadClientIdentifier()
        #if canImport(UIKit)
        self.deviceName = UIDevice.current.name
        self.deviceModel = UIDevice.current.model
        self.platformVersion = UIDevice.current.systemVersion
        #else
        self.deviceName = "Mac"
        self.deviceModel = "Mac"
        self.platformVersion = "1.0"
        #endif
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    func applyPlexHeaders(_ request: inout URLRequest, token: String? = nil) {
        request.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(appVersion, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(deviceModel, forHTTPHeaderField: "X-Plex-Device")
        request.setValue(deviceName, forHTTPHeaderField: "X-Plex-Device-Name")
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(platformVersion, forHTTPHeaderField: "X-Plex-Platform-Version")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("player", forHTTPHeaderField: "X-Plex-Provides")
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
    }

    func requestPlexPin() async throws -> PlexPin {

        guard let url = URL(string: "\(baseURL)/api/v2/pins") else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(&request)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                AppLogger.network.info("requestPlexPin: Non-HTTP response")
                throw PlexError.authenticationFailed
            }

            AppLogger.network.info("requestPlexPin status: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 200 && httpResponse.statusCode != 201 {
                AppLogger.network.error("requestPlexPin failed with HTTP \(httpResponse.statusCode)")
                throw PlexError.authenticationFailed
            }

            let decoder = JSONDecoder()
            let pinResponse = try decoder.decode(InternalPlexPinResponse.self, from: data)
            return PlexPin(
                id: pinResponse.id,
                code: pinResponse.code,
                authToken: nil,
                expiresAt: Date(timeIntervalSinceNow: TimeInterval(pinResponse.expiresIn)),
                clientIdentifier: pinResponse.clientIdentifier
            )
        } catch {
            if error is PlexError {
                throw error
            }
            AppLogger.network.error("requestPlexPin network error: \(error)")
            throw PlexError.networkError(error)
        }
    }

    func checkPlexPin(id: String) async throws -> String? {
        guard let url = URL(string: "\(baseURL)/api/v2/pins/\(id)?includeClient=1") else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(&request)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                AppLogger.network.info("checkPlexPin: Non-HTTP response")
                throw PlexError.authenticationFailed
            }

            AppLogger.network.info("checkPlexPin status: \(httpResponse.statusCode)")
            if httpResponse.statusCode != 200 {
                AppLogger.network.error("checkPlexPin failed with HTTP \(httpResponse.statusCode)")
                throw PlexError.authenticationFailed
            }

            let decoder = JSONDecoder()
            let pinResponse = try decoder.decode(InternalPlexPinResponse.self, from: data)
            AppLogger.network.info("checkPlexPin authToken: \(pinResponse.authToken != nil ? "<present>" : "<nil>")")
            return pinResponse.authToken
        } catch {
            if error is PlexError {
                throw error
            }
            AppLogger.network.error("checkPlexPin network error: \(error)")
            throw PlexError.networkError(error)
        }
    }

    struct PlexUser: Codable, Sendable {
        let id: Int?
        let uuid: String?
        let username: String?

        var accountId: String {
            if let uuid, !uuid.isEmpty { return uuid }
            if let id { return String(id) }
            if let username, !username.isEmpty { return username }
            return "unknown"
        }
    }

    func getCurrentUser(token: String) async throws -> PlexUser {
        guard let url = URL(string: "\(baseURL)/api/v2/user") else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(&request, token: token)

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PlexError.serverUnreachable
            }
            guard httpResponse.statusCode == 200 else {
                if httpResponse.statusCode == 401 {
                    throw PlexError.invalidToken
                }
                throw PlexError.unknownStatusCode(httpResponse.statusCode)
            }

            let decoder = JSONDecoder()
            return try decoder.decode(PlexUser.self, from: data)
        } catch {
            if error is PlexError {
                throw error
            }
            throw PlexError.networkError(error)
        }
    }

    func getPlexServers(token: String, ownerToken: String? = nil, switchedUserId: String? = nil) async throws -> [PlexServer] {
        let servers = try await fetchPlexServersFromResources(token: token)
        if !servers.isEmpty {
            return servers
        }

        guard let ownerToken,
            let switchedUserId,
            ownerToken != token
        else {
            return servers
        }

        AppLogger.network.info("Plex resources empty for switched user \(switchedUserId) - falling back to owner shared-server mappings")
        let fallbackServers = try await fetchSharedPlexServers(ownerToken: ownerToken, switchedUserId: switchedUserId)
        AppLogger.network.warning("Plex shared-server fallback returned \(fallbackServers.count) server(s)")
        return fallbackServers
    }

    private func fetchPlexServersFromResources(token: String) async throws -> [PlexServer] {
        guard let url = URL(string: "\(baseURL)/api/v2/resources?includeHttps=1&includeRelay=1") else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        applyPlexHeaders(&request, token: token)

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw PlexError.serverUnreachable
            }

            guard httpResponse.statusCode == 200 else {
                AppLogger.network.info("Plex Resources API returned status code: \(httpResponse.statusCode)")
                throw PlexError.unknownStatusCode(httpResponse.statusCode)
            }

            let resources = try parsePlexResourcesXML(data: data)

            AppLogger.network.info("Plex Resources API returned \(resources.count) server(s)")

            return resources.compactMap { resource in
                guard resource.provides == "server" else { return nil }

                let connections = resource.connections.map { conn in
                    PlexConnection(
                        uri: conn.uri,
                        local: conn.local,
                        protocol: conn.protocol,
                        address: conn.address,
                        port: conn.port,
                        relay: conn.relay
                    )
                }

                let server = PlexServer(
                    id: resource.clientIdentifier,
                    name: resource.name,
                    uri: resource.uri ?? "",
                    local: connections.first?.local ?? false,
                    httpsRequired: connections.contains(where: { $0.isSecure }),
                    owned: resource.owned,
                    synced: resource.synced,
                    accessToken: resource.accessToken.flatMap { $0.isEmpty ? nil : $0 } ?? token,
                    connections: connections
                )

                AppLogger.network.info("Server: \(server.name)")
                AppLogger.network.info("- Owned: \(server.owned ? "Yes" : "No (shared)")")
                AppLogger.network.info("- Machine ID: \(server.id)")
                AppLogger.network.info("- Connections: \(connections.count)")
                for (idx, conn) in connections.enumerated() {
                    let type = conn.local ? "LAN" : (conn.isRelay ? "Relay" : "WAN")
                    let secure = conn.isSecure ? "HTTPS" : "HTTP"
                    let direct = conn.isPlexDirect ? " (plex.direct)" : ""
                    AppLogger.network.info("\(idx + 1). [\(type)] \(secure)\(direct): \(conn.uri)")
                }

                return server
            }
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                throw CancellationError()
            }

            AppLogger.network.error("Error in getPlexServers: \(error)")
            if let decodingError = error as? DecodingError {
                AppLogger.network.error("Decoding error details: \(decodingError)")
            }
            if error is PlexError {
                throw error
            }
            throw PlexError.decodingError(error)
        }
    }

    private func fetchSharedPlexServers(ownerToken: String, switchedUserId: String) async throws -> [PlexServer] {
        let ownerServers = try await fetchPlexServersFromResources(token: ownerToken)
        guard !ownerServers.isEmpty else {
            return []
        }

        var sharedServers: [PlexServer] = []
        for ownerServer in ownerServers {
            do {
                guard
                    let sharedAccessToken = try await fetchSharedServerAccessToken(
                        ownerToken: ownerToken,
                        serverId: ownerServer.id,
                        switchedUserId: switchedUserId
                    )
                else {
                    continue
                }

                sharedServers.append(
                    PlexServer(
                        id: ownerServer.id,
                        name: ownerServer.name,
                        uri: ownerServer.uri,
                        local: ownerServer.local,
                        httpsRequired: ownerServer.httpsRequired,
                        owned: false,
                        synced: ownerServer.synced,
                        accessToken: sharedAccessToken,
                        connections: ownerServer.connections
                    )
                )
            } catch {
                AppLogger.network.error("Failed shared-server fallback lookup for \(ownerServer.name): \(error)")
            }
        }

        return sharedServers
    }

    private func fetchSharedServerAccessToken(ownerToken: String, serverId: String, switchedUserId: String) async throws -> String? {
        guard let url = URL(string: "\(baseURL)/api/servers/\(serverId)/shared_servers") else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        applyPlexHeaders(&request, token: ownerToken)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.serverUnreachable
        }

        guard httpResponse.statusCode == 200 else {
            AppLogger.network.info("Plex shared_servers returned status \(httpResponse.statusCode)")
            throw PlexError.unknownStatusCode(httpResponse.statusCode)
        }

        let sharedServers = try parseSharedServersXML(data: data)
        AppLogger.network.info("Parsed \(sharedServers.count) shared server entries, looking for userId=\(switchedUserId)")
        return sharedServers.first(where: { $0.matches(userId: switchedUserId) })?.accessToken
    }

    func resolveServerAccessToken(
        userToken: String,
        serverUrl: String,
        ownerToken: String? = nil,
        switchedUserId: String? = nil
    ) async -> String {
        let normalizedTarget = normalizedServerURL(serverUrl)
        let targetHostPort = normalizedHostPort(serverUrl)

        do {
            let servers = try await getPlexServers(token: userToken, ownerToken: ownerToken, switchedUserId: switchedUserId)

            for server in servers {
                if normalizedServerURL(server.uri) == normalizedTarget {
                    return server.accessToken
                }
                if server.connections.contains(where: { normalizedServerURL($0.uri) == normalizedTarget }) {
                    return server.accessToken
                }
            }

            let hostMatches = servers.filter { server in
                if normalizedHostPort(server.uri) == targetHostPort {
                    return true
                }
                return server.connections.contains { normalizedHostPort($0.uri) == targetHostPort }
            }

            if hostMatches.count == 1 {
                return hostMatches[0].accessToken
            }

            if servers.count == 1, let onlyServer = servers.first {
                return onlyServer.accessToken
            }
        } catch {
            AppLogger.network.error(
                "Failed to resolve server access token for \(URL(string: serverUrl)?.redacted.absoluteString ?? "<invalid>"): \(error.localizedDescription)"
            )
        }

        return userToken
    }

    private func normalizedServerURL(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString.lowercased()) else {
            return urlString.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }

        let scheme = components.scheme ?? ""
        let host = components.host ?? ""
        let port = components.port.map(String.init) ?? ""
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var normalized = "\(scheme)://\(host)"
        if !port.isEmpty {
            normalized += ":\(port)"
        }
        if !path.isEmpty {
            normalized += "/\(path)"
        }
        return normalized
    }

    private func normalizedHostPort(_ urlString: String) -> String {
        guard let components = URLComponents(string: urlString.lowercased()) else {
            return urlString.lowercased()
        }

        let host = components.host ?? ""
        let port = components.port.map(String.init) ?? ""
        return port.isEmpty ? host : "\(host):\(port)"
    }

    func verifyConnection(url: String, token: String) async -> Bool {
        guard let baseURL = URL(string: url) else {
            return false
        }
        let redactedURL = baseURL.redacted.absoluteString

        let probePaths = ["/library/sections", "/identity"]

        for path in probePaths {
            guard let probeURL = URL(string: path, relativeTo: baseURL) else { continue }

            var components = URLComponents(url: probeURL, resolvingAgainstBaseURL: true)
            var items = components?.queryItems ?? []
            items.append(URLQueryItem(name: "X-Plex-Token", value: token))
            components?.queryItems = items

            guard let finalURL = components?.url else { continue }

            var request = URLRequest(url: finalURL)
            request.setValue("application/xml", forHTTPHeaderField: "Accept")
            applyPlexHeaders(&request, token: token)
            request.timeoutInterval = 3.0

            do {
                let (_, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    let success = httpResponse.statusCode == 200
                    AppLogger.network.error("Tested \(redactedURL)\(path): \(success ? " OK" : " Failed (\(httpResponse.statusCode))")")
                    if success {
                        return true
                    }
                    continue
                }

                AppLogger.network.info("Tested \(redactedURL)\(path): Non-HTTP response")
            } catch {
                let nsError = error as NSError
                AppLogger.network.error(
                    "Tested \(redactedURL)\(path): Failed (\(nsError.domain) \(nsError.code)) \(nsError.localizedDescription)"
                )
            }
        }

        return false
    }

    func findBestConnection(server: PlexServer) async -> String? {
        AppLogger.network.info("Finding best connection for server: \(server.name)")
        AppLogger.network.info("Testing all Plex connections; local addresses are not assumed reachable")

        let sortedConnections = server.connections.sorted { conn1, conn2 in
            let conn1SecureRemote = conn1.isSecure && !conn1.local && !conn1.isRelay
            let conn2SecureRemote = conn2.isSecure && !conn2.local && !conn2.isRelay
            if conn1SecureRemote != conn2SecureRemote {
                return conn1SecureRemote
            }

            let conn1SecureLocal = conn1.isSecure && conn1.local && !conn1.isRelay
            let conn2SecureLocal = conn2.isSecure && conn2.local && !conn2.isRelay
            if conn1SecureLocal != conn2SecureLocal {
                return conn1SecureLocal
            }

            let conn1InsecureRemote = !conn1.isSecure && !conn1.local && !conn1.isRelay
            let conn2InsecureRemote = !conn2.isSecure && !conn2.local && !conn2.isRelay
            if conn1InsecureRemote != conn2InsecureRemote {
                return conn1InsecureRemote
            }

            let conn1InsecureLocal = !conn1.isSecure && conn1.local && !conn1.isRelay
            let conn2InsecureLocal = !conn2.isSecure && conn2.local && !conn2.isRelay
            if conn1InsecureLocal != conn2InsecureLocal {
                return conn1InsecureLocal
            }

            if conn1.isRelay != conn2.isRelay {
                return !conn1.isRelay
            }

            return false
        }

        AppLogger.network.info("Testing \(sortedConnections.count) connection(s) in priority order...")

        for (index, connection) in sortedConnections.enumerated() {
            let connectionType: String
            if connection.isRelay {
                connectionType = "Relay"
            } else if connection.local {
                connectionType = connection.isSecure ? "Local HTTPS" : "Local HTTP"
            } else {
                connectionType = connection.isSecure ? "Remote HTTPS" : "Remote HTTP"
            }

            AppLogger.network.info("[\(index + 1)/\(sortedConnections.count)] Testing \(connectionType): \(connection.uri)")

            if await verifyConnection(url: connection.uri, token: server.accessToken) {
                AppLogger.network.info("Found working connection: \(connection.uri)")
                AppLogger.network.info("Type: \(connectionType)")
                PlexAuthStore.shared.saveServerUrl(connection.uri)
                PlexAuthStore.shared.saveMachineIdentifier(server.id)
                PlexAuthStore.shared.saveServerAccessToken(server.accessToken)
                return connection.uri
            } else {
                AppLogger.network.error("Connection failed - trying next...")
            }
        }

        AppLogger.network.info("No working connection found after testing all \(sortedConnections.count) connection(s)")
        return nil
    }

    func getLibrarySectionsAuto(token: String) async throws -> [LibrarySection] {
        AppLogger.network.info("Loading Plex library (auto-detecting best connection)...")

        let servers = try await getPlexServers(token: token)

        guard let server = servers.first else {
            throw PlexError.serverUnreachable
        }

        AppLogger.network.info("Found server: \(server.name) (\(server.id))")
        AppLogger.network.info("Will test \(server.connections.count) connection(s) in priority order")

        guard let workingURL = await findBestConnection(server: server) else {
            AppLogger.network.info("No reachable connection found for server: \(server.name)")
            throw PlexError.serverUnreachable
        }

        AppLogger.network.info("Using verified connection: \(workingURL)")

        do {
            return try await getLibrarySections(serverUrl: workingURL, token: server.accessToken)
        } catch {
            AppLogger.network.error("Failed to fetch library sections from verified connection: \(error)")
            throw error
        }
    }

    func getLibrarySectionsWithFallback(serverUrl: String, token: String) async throws -> [LibrarySection] {
        do {
            AppLogger.network.info("Loading Plex library with provided URL...")
            return try await getLibrarySections(serverUrl: serverUrl, token: token)
        } catch {
            let nsError = error as NSError
            let isConnectionError =
                nsError.domain == NSURLErrorDomain
                && (nsError.code == NSURLErrorCannotFindHost || nsError.code == NSURLErrorCannotConnectToHost
                    || nsError.code == NSURLErrorNetworkConnectionLost || nsError.code == NSURLErrorTimedOut)

            if isConnectionError {
                AppLogger.network.error("Provided URL failed with connection error, fetching fresh server info...")
                return try await getLibrarySectionsAuto(token: token)
            } else {
                throw error
            }
        }
    }

    func getLibrarySections(serverUrl: String, token: String) async throws -> [LibrarySection] {
        AppLogger.network.info("Loading Plex library...")
        AppLogger.network.info("Server URL: \(URL(string: serverUrl)?.redacted.absoluteString ?? "<invalid>")")

        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/library/sections", relativeTo: baseURL)
        else {
            AppLogger.network.error("Invalid URL")
            throw PlexError.invalidURL
        }

        AppLogger.network.info("Full URL: \(url.redacted)")

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        let finalRequest = request

        AppLogger.network.warning("Making request with 10 second timeout...")
        let startTime = Date()

        do {
            let (data, response) = try await withTimeout(seconds: 15) {
                try await self.session.data(for: finalRequest)
            }
            let elapsed = Date().timeIntervalSince(startTime)
            AppLogger.network.info("Request completed in \(String(format: "%.2f", elapsed)) seconds")

            guard let httpResponse = response as? HTTPURLResponse else {
                AppLogger.network.error("Invalid response type")
                throw PlexError.serverUnreachable
            }

            guard httpResponse.statusCode == 200 else {
                AppLogger.network.info("Bad response status: \(httpResponse.statusCode)")
                if (400...599).contains(httpResponse.statusCode) {
                    throw PlexError.unknownStatusCode(httpResponse.statusCode)
                }
                throw PlexError.serverUnreachable
            }

            let sections = try parsePlexSectionsXML(data: data)

            AppLogger.network.info("Successfully loaded \(sections.count) library sections")

            return sections
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            AppLogger.network.error("Failed to load Plex library sections after \(String(format: "%.2f", elapsed)) seconds")
            AppLogger.network.error("Error: \(error.localizedDescription)")

            let nsError = error as NSError
            AppLogger.network.error("Error domain: \(nsError.domain), code: \(nsError.code)")

            let isConnectionError =
                nsError.domain == NSURLErrorDomain
                && (nsError.code == NSURLErrorCannotFindHost || nsError.code == NSURLErrorCannotConnectToHost
                    || nsError.code == NSURLErrorNetworkConnectionLost || nsError.code == NSURLErrorTimedOut
                    || nsError.code == NSURLErrorDNSLookupFailed)

            if isConnectionError {
                AppLogger.network.error("Connection error detected (code: \(nsError.code))")
                AppLogger.network.error("This connection failed - will need to try alternative connections")
                throw PlexError.networkError(error)
            }

            if error is PlexError {
                throw error
            }
            throw PlexError.decodingError(error)
        }
    }

    private static func extractBaseName(from filePath: String) -> String {
        let filename = URL(fileURLWithPath: filePath).deletingPathExtension().lastPathComponent
        var name = filename.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let trailingNumberPatterns = [
            #"\s*[-\x{2013}\x{2014}]?\s*(?:part|pt|chapter|ch\.?|track|disc|disk|section|#)\s*\d+\s*$"#,
            #"\s*[-\x{2013}\x{2014}]\s*\d+\s*$"#,
            #"\s+\d{1,4}\s*$"#,
        ]
        for pattern in trailingNumberPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(name.startIndex..., in: name)
                name = regex.stringByReplacingMatches(in: name, options: [], range: range, withTemplate: "")
            }
        }

        return name.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    static func groupTracksIntoBooks(_ books: [Book]) -> [Book] {
        guard books.count > 1 else { return books }

        var groups: [String: [Book]] = [:]
        var ungrouped: [Book] = []

        for book in books {
            if let filePath = book.filePath, !filePath.isEmpty {
                let parentDir = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
                let baseName = extractBaseName(from: filePath)
                let key = "\(parentDir)\0\(baseName)"
                groups[key, default: []].append(book)
            } else {
                let key = book.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                if key.isEmpty || key == "unknown" {
                    ungrouped.append(book)
                } else {
                    groups[key, default: []].append(book)
                }
            }
        }

        var result: [Book] = ungrouped

        for (groupKey, groupBooks) in groups {
            if groupBooks.count <= 1 {
                result.append(contentsOf: groupBooks)
                continue
            }

            let sorted = groupBooks.sorted { a, b in
                let aFile = a.filePath ?? a.title
                let bFile = b.filePath ?? b.title
                return aFile.localizedStandardCompare(bFile) == .orderedAscending
            }

            guard let primary = sorted.first else { continue }

            let bookTitle: String
            let basePart = groupKey.components(separatedBy: "\0").last ?? ""
            if !basePart.isEmpty {
                bookTitle = basePart.capitalized
            } else if let filePath = primary.filePath, !filePath.isEmpty {
                let folderName = URL(fileURLWithPath: filePath).deletingLastPathComponent().lastPathComponent
                bookTitle = folderName.isEmpty ? primary.title : folderName
            } else {
                bookTitle = primary.title
            }

            let totalDuration = sorted.reduce(0.0) { $0 + ($1.duration ?? 0) }

            let merged = Book(
                id: primary.id,
                ratingKey: primary.ratingKey,
                title: bookTitle,
                author: primary.author,
                narrator: primary.narrator,
                thumb: primary.thumb,
                partKey: primary.partKey,
                duration: totalDuration,
                chapters: nil,
                currentChapterIndex: nil,
                source: primary.source,
                backendId: primary.backendId,
                trackIndex: nil,
                filePath: primary.filePath,
                audioTracks: nil,
                description: primary.description,
                series: primary.series,
                seriesNumber: primary.seriesNumber,
                publishedYear: primary.publishedYear,
                genres: primary.genres,
                publisher: primary.publisher,
                isbn: primary.isbn,
                asin: primary.asin,
                addedAt: primary.addedAt,
                libraryName: primary.libraryName,
                backendName: primary.backendName,
                progress: primary.progress,
                lastPlayed: primary.lastPlayed
            )
            result.append(merged)
        }

        return result
    }

    func getLibrarySectionsWithRetry(server: PlexServer) async throws -> [LibrarySection] {
        AppLogger.network.info("Loading Plex library with automatic connection verification...")

        var lastError: Error?
        var triedUrls: Set<String> = []

        let sortedConnections = server.connections.sorted { conn1, conn2 in
            let conn1SecureRemote = conn1.isSecure && !conn1.local && !conn1.isRelay
            let conn2SecureRemote = conn2.isSecure && !conn2.local && !conn2.isRelay
            if conn1SecureRemote != conn2SecureRemote { return conn1SecureRemote }

            let conn1SecureLocal = conn1.isSecure && conn1.local && !conn1.isRelay
            let conn2SecureLocal = conn2.isSecure && conn2.local && !conn2.isRelay
            if conn1SecureLocal != conn2SecureLocal { return conn1SecureLocal }

            let conn1InsecureRemote = !conn1.isSecure && !conn1.local && !conn1.isRelay
            let conn2InsecureRemote = !conn2.isSecure && !conn2.local && !conn2.isRelay
            if conn1InsecureRemote != conn2InsecureRemote { return conn1InsecureRemote }

            let conn1InsecureLocal = !conn1.isSecure && conn1.local && !conn1.isRelay
            let conn2InsecureLocal = !conn2.isSecure && conn2.local && !conn2.isRelay
            if conn1InsecureLocal != conn2InsecureLocal { return conn1InsecureLocal }

            if conn1.isRelay != conn2.isRelay { return !conn1.isRelay }

            return false
        }

        AppLogger.network.info("Will try \(sortedConnections.count) connection(s) in priority order...")

        for (index, connection) in sortedConnections.enumerated() {
            if triedUrls.contains(connection.uri) { continue }
            triedUrls.insert(connection.uri)

            let connectionType: String
            if connection.isRelay {
                connectionType = "Relay"
            } else if connection.local {
                connectionType = connection.isSecure ? "Local HTTPS" : "Local HTTP"
            } else {
                connectionType = connection.isSecure ? "Remote HTTPS" : "Remote HTTP"
            }

            AppLogger.network.info("Attempt \(index + 1)/\(sortedConnections.count): Verifying \(connectionType): \(connection.uri)")

            if await verifyConnection(url: connection.uri, token: server.accessToken) {
                AppLogger.network.info("Connection verified: \(connection.uri)")
                do {
                    return try await getLibrarySections(serverUrl: connection.uri, token: server.accessToken)
                } catch {
                    AppLogger.network.error("Failed to load library from verified connection: \(error.localizedDescription)")
                    lastError = error
                    continue
                }
            } else {
                AppLogger.network.error("Connection failed verification: \(connection.uri)")
            }
        }

        AppLogger.network.error("All \(sortedConnections.count) connection attempt(s) failed")
        throw lastError ?? PlexError.serverUnreachable
    }

    func getAudiobooks(serverUrl: String, token: String, sectionKey: String, sectionTitle: String? = nil) async throws -> [Book] {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/library/sections/\(sectionKey)/all?type=10", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                throw PlexError.serverUnreachable
            }

            let books = try parsePlexAudiobooksXML(
                data: data,
                serverUrl: serverUrl,
                token: token,
                sectionKey: sectionKey,
                sectionTitle: sectionTitle
            )
            return Self.groupTracksIntoBooks(books)
        } catch {
            if error is PlexError {
                throw error
            }
            throw PlexError.decodingError(error)
        }
    }

    func getChapters(serverUrl: String, token: String, ratingKey: String) async throws -> [Chapter] {
        guard let baseURL = URL(string: serverUrl) else {
            AppLogger.network.error("Invalid server URL")
            throw PlexError.invalidURL
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/library/metadata/\(ratingKey)"
        components?.queryItems = [
            URLQueryItem(name: "includeChapters", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ]

        guard let url = components?.url else {
            AppLogger.network.error("Failed to construct chapter URL")
            throw PlexError.invalidURL
        }

        AppLogger.network.info("Fetching chapters from: \(url.redacted)")

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        do {
            AppLogger.network.info("Making request to Plex server...")
            let (data, response) = try await session.data(for: request)

            AppLogger.network.info("Received response: \(data.count) bytes")

            guard let httpResponse = response as? HTTPURLResponse else {
                AppLogger.network.info("Response is not HTTPURLResponse")
                throw PlexError.serverUnreachable
            }

            AppLogger.network.info("HTTP Status: \(httpResponse.statusCode)")

            guard httpResponse.statusCode == 200 else {
                AppLogger.network.error("HTTP error: \(httpResponse.statusCode)")
                throw PlexError.serverUnreachable
            }

            let chapters = try parsePlexChaptersXML(data: data)
            AppLogger.network.info("Parsed \(chapters.count) chapters from Plex")
            if chapters.isEmpty {
                AppLogger.network.info("No chapters found in XML response")
            } else {
                for (idx, chapter) in chapters.enumerated() {
                    AppLogger.network.debug(
                        "Chapter \(idx + 1) start=\(chapter.start)s end=\(chapter.end)s"
                    )
                }
            }
            return chapters
        } catch let urlError as URLError {
            AppLogger.network.error("URLError while fetching chapters: \(urlError.localizedDescription)")
            AppLogger.network.error("Error code: \(urlError.code.rawValue)")
            if urlError.code == .timedOut {
                AppLogger.network.info("Request timed out")
            }
            throw PlexError.serverUnreachable
        } catch {
            AppLogger.network.error("Error while fetching chapters: \(error.localizedDescription)")
            if error is PlexError {
                throw error
            }
            throw PlexError.decodingError(error)
        }
    }

    func getCollections(serverUrl: String, token: String, sectionKey: String) async throws -> [PlexCollection] {
        guard let baseURL = URL(string: serverUrl),
            let url = URL(string: "/library/sections/\(sectionKey)/collections", relativeTo: baseURL)
        else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                httpResponse.statusCode == 200
            else {
                throw PlexError.serverUnreachable
            }

            let collections = try parsePlexCollectionsXML(data: data, serverUrl: serverUrl, token: token, sectionKey: sectionKey)
            return collections
        } catch {
            if error is PlexError {
                throw error
            }
            throw PlexError.decodingError(error)
        }
    }

    func getCollectionBooks(serverUrl: String, token: String, collectionKey: String) async throws -> [Book] {
        return try await getCollectionBooks(
            serverUrl: serverUrl,
            token: token,
            collectionKey: collectionKey,
            containerStart: nil,
            containerSize: nil
        )
    }

    func getCollectionBooks(
        serverUrl: String,
        token: String,
        collectionKey: String,
        containerStart: Int?,
        containerSize: Int?
    ) async throws -> [Book] {
        guard let baseURL = URL(string: serverUrl) else { throw PlexError.invalidURL }

        func makeURL(path: String, extraQueryItems: [URLQueryItem] = []) throws -> URL {
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            components?.path = path

            var queryItems: [URLQueryItem] = []
            if let containerStart {
                queryItems.append(URLQueryItem(name: "X-Plex-Container-Start", value: String(containerStart)))
            }
            if let containerSize {
                queryItems.append(URLQueryItem(name: "X-Plex-Container-Size", value: String(containerSize)))
            }
            queryItems.append(contentsOf: extraQueryItems)
            components?.queryItems = queryItems.isEmpty ? nil : queryItems

            guard let url = components?.url else { throw PlexError.invalidURL }
            return url
        }

        let candidateRequests: [(label: String, url: URL)] = [
            ("metadata/children", try makeURL(path: "/library/metadata/\(collectionKey)/children")),
            (
                "metadata/children?type=9",
                try makeURL(path: "/library/metadata/\(collectionKey)/children", extraQueryItems: [URLQueryItem(name: "type", value: "9")])
            ),
            ("collections/children", try makeURL(path: "/library/collections/\(collectionKey)/children")),
            (
                "collections/children?type=9",
                try makeURL(
                    path: "/library/collections/\(collectionKey)/children",
                    extraQueryItems: [URLQueryItem(name: "type", value: "9")]
                )
            ),
        ]

        var lastLabel: String?

        for candidate in candidateRequests {
            var request = URLRequest(url: candidate.url)
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
            request.setValue(product, forHTTPHeaderField: "X-Plex-Product")
            request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
            request.setValue("application/xml", forHTTPHeaderField: "Accept")

            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                    httpResponse.statusCode == 200
                else {
                    continue
                }

                let books = try parsePlexAudiobooksXML(
                    data: data,
                    serverUrl: serverUrl,
                    token: token,
                    sectionKey: collectionKey,
                    sectionTitle: nil
                )
                if !books.isEmpty {
                    return books
                }

                lastLabel = candidate.label
            } catch {
                continue
            }
        }

        if let lastLabel {
            AppLogger.network.info("Plex collection '\(collectionKey)' returned 0 parsed book(s) after trying '\(lastLabel)'")
        } else {
            AppLogger.network.info("Plex collection '\(collectionKey)' returned 0 parsed book(s) after trying all known endpoints")
        }

        return []
    }

    func getStreamUrl(serverUrl: String, partKey: String, token: String, ratingKey: String) -> URL? {
        guard let baseURL = URL(string: serverUrl) else {
            AppLogger.network.error("Invalid server URL")
            return nil
        }

        let path: String
        if partKey.hasPrefix("/library/parts/") {
            path = partKey
        } else if partKey.hasPrefix("library/parts/") {
            path = "/\(partKey)"
        } else {
            path = "/library/parts/\(partKey)"
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: token),
            URLQueryItem(name: "download", value: "0"),
        ]

        guard let streamURL = components?.url else {
            AppLogger.network.error("Failed to construct stream URL")
            return nil
        }

        AppLogger.network.info("Plex stream URL: \(streamURL.redacted)")
        return streamURL
    }

    func reportProgress(
        serverUrl: String,
        token: String,
        ratingKey: String,
        time: TimeInterval,
        duration: TimeInterval,
        state: String = "playing"
    ) async throws {
        guard let baseURL = URL(string: serverUrl) else {
            throw PlexError.invalidURL
        }

        let timeMs = Int(time * 1000)
        guard timeMs >= 60001 else {
            AppLogger.network.warning("Skipping progress report: time (\(timeMs)ms) is less than minimum (60001ms)")
            return
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/:/progress"
        components?.queryItems = [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "time", value: String(timeMs)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "X-Plex-Token", value: token),
        ]

        guard let url = components?.url else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                AppLogger.network.error("Progress report failed: Invalid response type")
                throw PlexError.serverUnreachable
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                AppLogger.network.error("Progress report failed: HTTP \(httpResponse.statusCode)")
                if (400...599).contains(httpResponse.statusCode) {
                    throw PlexError.unknownStatusCode(httpResponse.statusCode)
                }
                throw PlexError.serverUnreachable
            }

            AppLogger.network.info("Progress reported successfully: \(timeMs)ms (state: \(state))")
        } catch {
            AppLogger.network.error("Failed to report playback progress: \(error.localizedDescription)")
            if error is PlexError {
                throw error
            }
            throw PlexError.networkError(error)
        }
    }

    func fetchProgress(serverUrl: String, token: String, ratingKey: String) async throws -> (offset: TimeInterval, duration: TimeInterval)?
    {
        guard let baseURL = URL(string: serverUrl) else {
            throw PlexError.invalidURL
        }

        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/library/metadata/\(ratingKey)"
        components?.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: token),
            URLQueryItem(name: "includeChildren", value: "1"),
        ]

        guard let url = components?.url else { throw PlexError.invalidURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue(product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw PlexError.serverUnreachable
            }

            let xml = String(data: data, encoding: .utf8) ?? ""
            let parsed = parseProgressXML(xml: xml)

            if let offsetMs = parsed.viewOffset {
                let duration = Double(parsed.duration ?? 0) / 1000.0
                return (offset: TimeInterval(offsetMs) / 1000.0, duration: duration)
            }
            return nil
        } catch {
            if error is PlexError { throw error }
            throw PlexError.networkError(error)
        }
    }

    private func parseProgressXML(xml: String) -> (viewOffset: Int?, duration: Int?) {
        var viewOffset: Int?
        var duration: Int?

        if let range = xml.range(of: "viewOffset=\"", options: .caseInsensitive) {
            let start = range.upperBound
            let rest = xml[start...]
            if let endQuote = rest.firstIndex(of: "\"") {
                let valueStr = rest[..<endQuote]
                viewOffset = Int(valueStr)
            }
        }

        if let range = xml.range(of: "duration=\"", options: .caseInsensitive) {
            let start = range.upperBound
            let rest = xml[start...]
            if let endQuote = rest.firstIndex(of: "\"") {
                let valueStr = rest[..<endQuote]
                duration = Int(valueStr)
            }
        }

        return (viewOffset, duration)
    }

    func getPlexHomeUsers(token: String) async throws -> [PlexHomeUser] {
        guard let url = URL(string: "\(baseURL)/api/v2/home/users") else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(&request, token: token)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.serverUnreachable
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw PlexError.invalidToken
            }
            throw PlexError.unknownStatusCode(httpResponse.statusCode)
        }

        let decoded = try JSONDecoder().decode(PlexHomeUsersResponse.self, from: data)
        let users = (decoded.users ?? []).map { $0.toPlexHomeUser() }

        AppLogger.network.info("[PlexService] Found \(users.count) Plex Home user(s)")
        for user in users {
            let role = user.isAdmin ? "admin" : (user.isManaged ? "managed" : "friend")
            let pin = user.hasPin ? " " : ""
            AppLogger.network.info("- \(user.displayName) (\(role))\(pin)")
        }

        return users
    }

    func switchPlexHomeUser(userId: String, token: String, pin: String? = nil) async throws -> PlexSwitchUserResponse {
        guard var urlComponents = URLComponents(string: "\(baseURL)/api/home/users/\(userId)/switch") else {
            throw PlexError.invalidURL
        }

        if let pin, !pin.isEmpty {
            urlComponents.queryItems = [URLQueryItem(name: "pin", value: pin)]
        }

        guard let url = urlComponents.url else {
            throw PlexError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        applyPlexHeaders(&request, token: token)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.serverUnreachable
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 {
                throw PlexError.authenticationFailed
            }
            AppLogger.network.error("Switch user failed with HTTP \(httpResponse.statusCode)")
            throw PlexError.unknownStatusCode(httpResponse.statusCode)
        }

        let decoded = try parseSwitchUserXML(data: data, userId: userId)

        guard decoded.authToken != nil else {
            AppLogger.network.info("Switch user succeeded but no authToken returned")
            throw PlexError.authenticationFailed
        }

        AppLogger.network.info(
            "Switched Plex Home user diagnosticID=\(DiagnosticLogSanitizer.identifier(for: decoded.title ?? decoded.username ?? userId))"
        )
        return decoded
    }

    private func parseSwitchUserXML(data: Data, userId: String) throws -> PlexSwitchUserResponse {
        let parser = XMLParser(data: data)
        let delegate = PlexSwitchUserXMLDelegate()
        parser.delegate = delegate
        parser.parse()
        if let error = delegate.parseError { throw PlexError.decodingError(error) }
        if let result = delegate.result {
            return result
        }

        if let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let idValue = jsonObject["id"] as? Int
            let uuidValue = jsonObject["uuid"] as? String
            let authTokenValue = (jsonObject["authenticationToken"] as? String) ?? (jsonObject["authToken"] as? String)
            let titleValue = jsonObject["title"] as? String
            let usernameValue = jsonObject["username"] as? String
            let thumbValue = jsonObject["thumb"] as? String

            if authTokenValue != nil {
                return PlexSwitchUserResponse(
                    id: idValue,
                    uuid: uuidValue,
                    authToken: authTokenValue,
                    title: titleValue,
                    username: usernameValue,
                    thumb: thumbValue
                )
            }
        }

        AppLogger.network.info("Unrecognized switch-user response for user \(userId)")
        throw PlexError.decodingError(
            NSError(
                domain: "PlexService",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No authentication token found in switch response"]
            )
        )
    }

}

private struct InternalPlexPinResponse: Decodable {
    let id: String
    let code: String
    let authToken: String?
    let expiresIn: Int
    let clientIdentifier: String?

    enum CodingKeys: String, CodingKey {
        case id, code, authToken, expiresIn, clientIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let idString = try? container.decode(String.self, forKey: .id) {
            id = idString
        } else if let idInt = try? container.decode(Int.self, forKey: .id) {
            id = String(idInt)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Plex pin id is neither String nor Int"
                )
            )
        }
        code = try container.decode(String.self, forKey: .code)
        authToken = try container.decodeIfPresent(String.self, forKey: .authToken)
        expiresIn = try container.decode(Int.self, forKey: .expiresIn)
        clientIdentifier = try container.decodeIfPresent(String.self, forKey: .clientIdentifier)
    }
}
