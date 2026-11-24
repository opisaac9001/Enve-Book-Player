import AVFoundation
import Foundation
import Logging

#if canImport(UIKit)
import UIKit
#endif

enum MediaBrowserClient {
    static let clientName = "Enve"

    static var clientVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var deviceId: String {
        #if canImport(UIKit)
        return UIDevice.current.identifierForVendor?.uuidString ?? StorageService.shared.loadDeviceUUID()
        #else
        return StorageService.shared.loadDeviceUUID()
        #endif
    }

    static var deviceName: String {
        #if canImport(UIKit)
        return UIDevice.current.name.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        #elseif os(macOS)
        return (Host.current().localizedName ?? "Mac").replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        #else
        return "Enve Client"
        #endif
    }

    static func authorizationHeader(token: String?) -> String {
        var header =
            "MediaBrowser Client=\"\(clientName)\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
        if let token {
            header += ", Token=\"\(token)\""
        }
        return header
    }

    static func validateUser(
        connection: ServerConnection,
        send: (URLRequest) async throws -> (Data, URLResponse)
    ) async throws -> String? {
        struct User: Decodable {
            let Id: String
            let Name: String?
        }

        guard let base = URL(string: normalizeServerURL(connection.url)),
            let token = connection.token, !token.isEmpty else { throw ProviderError.unauthorized }
        let selectedID = connection.userId.flatMap { $0.isEmpty ? nil : $0 }
        let userURL = base.appendingPathComponent("Users").appendingPathComponent(selectedID ?? "Me")
        var request = URLRequest(url: userURL)
        for (name, value) in connection.customHeaders ?? [:] {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(nil, forHTTPHeaderField: "X-Emby-Token")
        let auth = authorizationHeader(token: token)
        if connection.type == .jellyfin {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        if http.statusCode == 401 { throw ProviderError.unauthorized }
        guard http.statusCode == 200 else { return nil }
        let user = try JSONDecoder().decode(User.self, from: data)
        guard !user.Id.isEmpty else { return nil }
        if let selectedID {
            guard user.Id.caseInsensitiveCompare(selectedID) == .orderedSame else { return nil }
        } else if let name = connection.username, !name.isEmpty {
            guard user.Name?.caseInsensitiveCompare(name) == .orderedSame else { return nil }
        }
        return user.Id
    }

    // Jellyfin and Emby share the Sessions/Playing playstate API; a nil event is a periodic progress ping.
    static func playstateRequest(
        baseURL: String,
        event: ServerPlaybackEvent?,
        itemId: String,
        sessionId: String,
        position: TimeInterval
    ) -> URLRequest? {
        let path: String
        switch event {
        case .started: path = "/Sessions/Playing"
        case .stopped: path = "/Sessions/Playing/Stopped"
        case .paused, .resumed, nil: path = "/Sessions/Playing/Progress"
        }
        guard let url = URL(string: baseURL + path) else { return nil }
        var body: [String: Any] = [
            "ItemId": itemId,
            "PlaySessionId": sessionId,
            "PositionTicks": Int64(max(0, position) * 10_000_000),
            "CanSeek": true,
            "PlayMethod": "DirectStream",
            "IsPaused": event == .paused,
        ]
        switch event {
        case .paused: body["EventName"] = "Pause"
        case .resumed: body["EventName"] = "Unpause"
        case nil: body["EventName"] = "TimeUpdate"
        case .started, .stopped: break
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func normalizeServerURL(_ input: String) -> String {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if trimmed.isEmpty { return input }

        if !trimmed.lowercased().hasPrefix("http") {
            if trimmed.contains("8920") {
                trimmed = "https://\(trimmed)"
            } else {
                trimmed = "http://\(trimmed)"
            }
        }

        return trimmed
    }

    static func extractChapters(fromStream url: URL) async -> [Chapter] {
        let asset = AVURLAsset(url: url)
        var chapters: [Chapter] = []

        do {
            let locales = try await asset.load(.availableChapterLocales)
            for locale in locales {
                let metadataGroups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: [locale.identifier])
                for (index, group) in metadataGroups.enumerated() {
                    let start = CMTimeGetSeconds(group.timeRange.start)
                    let duration = CMTimeGetSeconds(group.timeRange.duration)

                    var title = "Chapter \(index + 1)"
                    for item in group.items where item.commonKey == .commonKeyTitle {
                        if let value = try? await item.load(.stringValue) {
                            title = value
                            break
                        }
                    }

                    chapters.append(Chapter(id: "extracted_\(index)", start: start, end: start + duration, title: title))
                }
                if !chapters.isEmpty { break }
            }
        } catch {
            AppLogger.network.error("Chapter extraction failed: \(error)")
        }

        return chapters.sorted { $0.start < $1.start }
    }
}
