import AVFoundation
import Foundation
import Logging

@MainActor
final class MetadataLayeringManager {
    static let shared = MetadataLayeringManager()

    private let playbackStateManager = PlaybackStateManager.shared

    func getChapters(for book: Book) async throws -> [Chapter]? {
        return book.chapters
    }

    func extractChapters(for book: Book) async -> [Chapter]? {
        if book.isMultiFile, let tracks = book.audioTracks, tracks.count > 1 {
            AppLogger.network.debug(
                "Extracting multi-file chapters bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            var chapters: [Chapter] = []
            for (index, track) in tracks.enumerated() {
                let title = track.title ?? "Chapter \(index + 1)"
                let chapter = Chapter(
                    id: "\(index)",
                    start: track.startOffset,
                    end: track.startOffset + track.duration,
                    title: title,
                    index: index
                )
                chapters.append(chapter)
            }
            return chapters.isEmpty ? nil : chapters
        }

        if let localFiles = LocalStorageManager.shared.localAudiobookFilesIfExists(for: book) {
            for fileURL in localFiles {
                if let chapters = await extractEmbeddedChapters(from: fileURL), !chapters.isEmpty {
                    AppLogger.network.debug(
                        "Extracted \(chapters.count) chapters from \(DiagnosticLogSanitizer.fileDescriptor(for: fileURL))"
                    )
                    return chapters
                }
            }
        }

        let provider = AppState.shared.providerConnections.capability(PlaybackSessionProvider.self, for: book)
        var audioURL: URL?
        if let path = book.filePath, FileManager.default.fileExists(atPath: path) {
            audioURL = URL(fileURLWithPath: path)
        } else if let direct = provider?.chapterExtractionURL(for: book) {
            audioURL = direct
        } else if let path = book.filePath {
            audioURL = URL(string: path)
        } else if let partKey = book.partKey {
            audioURL = URL(string: partKey)
        } else if let contentUrl = book.audioTracks?.first?.contentUrl {
            audioURL = URL(string: contentUrl)
        }

        guard let validURL = audioURL else {
            AppLogger.network.error(
                "Cannot extract chapters: no valid audio URL bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            return nil
        }

        let headers: [String: String]? = validURL.isFileURL ? nil : provider?.getStreamingHeaders()
        AppLogger.network.debug(
            "Extracting embedded chapters bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) sourceId=\(DiagnosticLogSanitizer.identifier(for: validURL.absoluteString))"
        )
        return await extractEmbeddedChapters(from: validURL, headers: headers)
    }

    @MainActor
    func extractEmbeddedChapters(from audioFileURL: URL, headers: [String: String]? = nil) async -> [Chapter]? {
        func makeAsset(mimeType: String? = nil) -> AVURLAsset {
            var options: [String: Any] = [:]
            if let headers, !headers.isEmpty {
                options["AVURLAssetHTTPHeaderFieldsKey"] = headers
            }
            if let mimeType {
                options["AVURLAssetOutOfBandMIMETypeKey"] = mimeType
            }
            return AVURLAsset(url: audioFileURL, options: options)
        }

        func readChapters(from asset: AVURLAsset) async throws -> [Chapter]? {
            let locales = try await asset.load(.availableChapterLocales)
            var chapterGroups: [AVTimedMetadataGroup]?

            for locale in locales {
                if let groups = try? await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: []),
                    !groups.isEmpty
                {
                    chapterGroups = groups
                    break
                }
            }

            if chapterGroups?.isEmpty != false {
                chapterGroups = try? await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: Locale.preferredLanguages)
            }

            guard let validGroups = chapterGroups, !validGroups.isEmpty else {
                return nil
            }

            var chapters: [Chapter] = []
            for (index, group) in validGroups.enumerated() {
                let startTime = CMTimeGetSeconds(group.timeRange.start)
                let endTime = CMTimeGetSeconds(CMTimeRangeGetEnd(group.timeRange))

                var title = "Chapter \(index + 1)"
                for item in group.items {
                    if let value = try? await item.load(.stringValue), !value.isEmpty {
                        title = value
                        break
                    }
                }

                let chapter = Chapter(
                    id: "\(index)",
                    start: startTime,
                    end: endTime,
                    title: title,
                    index: index
                )
                chapters.append(chapter)
            }

            return chapters
        }

        do {
            let primaryAsset = makeAsset()
            let durationHint = try? await primaryAsset.load(.duration).seconds
            if let chapters = await RemoteMP4ChapterExtractor.extractChapters(
                from: audioFileURL,
                headers: headers ?? [:],
                durationHint: durationHint
            ), !chapters.isEmpty {
                AppLogger.network.debug(
                    "Extracted \(chapters.count) ranged MP4 chapters sourceId=\(DiagnosticLogSanitizer.identifier(for: audioFileURL.absoluteString))"
                )
                return chapters
            }

            if let chapters = try await readChapters(from: primaryAsset), !chapters.isEmpty {
                AppLogger.network.debug(
                    "Extracted \(chapters.count) chapters sourceId=\(DiagnosticLogSanitizer.identifier(for: audioFileURL.absoluteString))"
                )
                return chapters
            }

            if !audioFileURL.isFileURL, audioFileURL.pathExtension.isEmpty,
                let chapters = try await readChapters(from: makeAsset(mimeType: "audio/mp4")),
                !chapters.isEmpty
            {
                AppLogger.network.info(
                    "Extracted \(chapters.count) chapters from extensionless audio/mp4 sourceId=\(DiagnosticLogSanitizer.identifier(for: audioFileURL.absoluteString))"
                )
                return chapters
            }

            AppLogger.network.debug(
                "No chapters found sourceId=\(DiagnosticLogSanitizer.identifier(for: audioFileURL.absoluteString))"
            )
            return nil
        } catch {
            AppLogger.network.error("Failed to extract chapters: \(error)")
            return nil
        }
    }
}
