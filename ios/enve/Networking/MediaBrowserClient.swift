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
