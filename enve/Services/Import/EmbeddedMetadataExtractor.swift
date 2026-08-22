import AVFoundation
import Foundation
import Logging

struct EmbeddedMetadataResult {
    var title: String?
    var author: String?
    var narrator: String?
    var series: String?
    var seriesNumber: String?
    var publishedYear: Int?
    var publisher: String?
    var genres: [String]?
    var description: String?
    var duration: TimeInterval?
    var copyright: String?
    var language: String?
    var encodingTool: String?
}

enum EmbeddedMetadataError: LocalizedError {
    case timeout
    case loadFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Metadata extraction timed out"
        case .loadFailed(let message):
            return "Failed to load metadata: \(message)"
        }
    }
}

final class EmbeddedMetadataExtractor {
    static let shared = EmbeddedMetadataExtractor()

    private init() {}

    func extractMetadata(
        from url: URL,
        headers: [String: String] = [:],
        timeout: TimeInterval = 10.0
    ) async throws -> EmbeddedMetadataResult {
        return try await withThrowingTaskGroup(of: EmbeddedMetadataResult.self) { group in
            group.addTask {
                let options: [String: Any] =
                    headers.isEmpty
                    ? [:]
                    : ["AVURLAssetHTTPHeaderFieldsKey": headers]
                let asset = AVURLAsset(url: url, options: options)
                return try await self.extractMetadata(from: asset)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw EmbeddedMetadataError.timeout
            }

            guard let result = try await group.next() else {
                throw EmbeddedMetadataError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    private func extractMetadata(from asset: AVURLAsset) async throws -> EmbeddedMetadataResult {
        var result = EmbeddedMetadataResult()

        do {
            let durationValue = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(durationValue)
            if seconds > 0 { result.duration = seconds }
        } catch {
            AppLogger.general.debug("Embedded duration probe failed: \(error.localizedDescription)")
        }

        let commonItems: [AVMetadataItem]
        do {
            commonItems = try await asset.load(.commonMetadata)
        } catch {
            commonItems = []
        }

        for item in commonItems {
            guard let key = item.commonKey?.rawValue else { continue }
            let trimmed: String
            if let s = try? await item.load(.value) as? String {
                trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                continue
            }
            if trimmed.isEmpty { continue }

            switch key {
            case AVMetadataKey.commonKeyTitle.rawValue:
                result.title = trimmed
            case AVMetadataKey.commonKeyArtist.rawValue:
                result.author = trimmed
            case AVMetadataKey.commonKeyAlbumName.rawValue:
                result.series = result.series ?? trimmed
            case AVMetadataKey.commonKeyDescription.rawValue:
                result.description = trimmed
            case AVMetadataKey.commonKeyType.rawValue:
                result.narrator = result.narrator ?? trimmed
            case AVMetadataKey.commonKeyLanguage.rawValue:
                result.language = result.language ?? trimmed
            default:
                break
            }
        }

        let allItems: [AVMetadataItem]
        do {
            allItems = try await asset.load(.metadata)
        } catch {
            allItems = []
        }

        for item in allItems {
            guard let identifier = item.identifier?.rawValue else { continue }

            let stringVal: String?
            if let s = try? await item.load(.value) as? String {
                stringVal = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                stringVal = nil
            }

            switch identifier {
            case AVMetadataIdentifier.iTunesMetadataTrackSubTitle.rawValue:
                result.series = result.series ?? stringVal.flatMap { $0.isEmpty ? nil : $0 }
            case AVMetadataIdentifier.iTunesMetadataArtist.rawValue:
                result.author = result.author ?? stringVal.flatMap { $0.isEmpty ? nil : $0 }
            case AVMetadataIdentifier.iTunesMetadataAlbum.rawValue:
                result.series = result.series ?? stringVal.flatMap { $0.isEmpty ? nil : $0 }
            case AVMetadataIdentifier.iTunesMetadataAlbumArtist.rawValue:
                result.author = result.author ?? stringVal.flatMap { $0.isEmpty ? nil : $0 }
            case AVMetadataIdentifier.iTunesMetadataComposer.rawValue:
                result.narrator = result.narrator ?? stringVal.flatMap { $0.isEmpty ? nil : $0 }
            case AVMetadataIdentifier.iTunesMetadataReleaseDate.rawValue:
                result.publishedYear = result.publishedYear ?? stringVal.flatMap { extractYear(from: $0) }
            case AVMetadataIdentifier.iTunesMetadataPublisher.rawValue:
                result.publisher = stringVal.flatMap { $0.isEmpty ? nil : $0 }
            case AVMetadataIdentifier.iTunesMetadataUserComment.rawValue:
                result.description = result.description ?? stringVal.flatMap { $0.isEmpty ? nil : $0 }
            case AVMetadataIdentifier.iTunesMetadataDescription.rawValue:
                result.description = result.description ?? stringVal.flatMap { $0.isEmpty ? nil : $0 }
            case "ilst/ldes":
                if let val = stringVal, !val.isEmpty {
                    if let existing = result.description {
                        if val.count > existing.count { result.description = val }
                    } else {
                        result.description = val
                    }
                }
            case AVMetadataIdentifier.iTunesMetadataUserGenre.rawValue:
                if let val = stringVal, !val.isEmpty {
                    var genres = result.genres ?? []
                    if !genres.contains(val) { genres.append(val) }
                    result.genres = genres
                }
            case "ilst/cprt":
                result.copyright = stringVal.flatMap { $0.isEmpty ? nil : $0 }
            case AVMetadataIdentifier.iTunesMetadataEncodingTool.rawValue:
                result.encodingTool = stringVal.flatMap { $0.isEmpty ? nil : $0 }
            default:
                if identifier.lowercased().contains("genre") {
                    if let val = stringVal, !val.isEmpty {
                        var genres = result.genres ?? []
                        if !genres.contains(val) { genres.append(val) }
                        result.genres = genres
                    }
                }
                if identifier.lowercased().contains("language") || identifier.contains("lang") {
                    result.language = result.language ?? stringVal.flatMap { $0.isEmpty ? nil : $0 }
                }
                break
            }
        }

        return result
    }

    private func extractYear(from dateString: String) -> Int? {
        let yearPattern = #"\b(19|20)\d{2}\b"#
        if let range = dateString.range(of: yearPattern, options: .regularExpression) {
            return Int(String(dateString[range]))
        }
        return nil
    }
}
