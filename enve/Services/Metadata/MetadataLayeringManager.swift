import AVFoundation
import Foundation
import Logging

@MainActor
final class MetadataLayeringManager {
    static let shared = MetadataLayeringManager()

    private let playbackStateManager = PlaybackStateManager.shared

    func getLayeredMetadata(
        book: Book,
        embedded: FileMetadataLayer? = nil
    ) throws -> ResolvedMetadata {
        let embeddedData = embedded

        let serverData = extractServerMetadata(from: book)

        let overrides = try playbackStateManager.loadMetadataOverride(for: book.id)

        return ResolvedMetadata(
            embedded: embeddedData,
            server: serverData,
            userOverrides: overrides
        )
    }

    private func extractServerMetadata(from book: Book) -> FileMetadataLayer {
        let folderName = book.filePath.flatMap { path -> String? in
            let url = URL(fileURLWithPath: path)
            return url.deletingLastPathComponent().lastPathComponent
        }
        let fileName = book.filePath.flatMap { path -> String? in
            let url = URL(fileURLWithPath: path)
            return url.deletingPathExtension().lastPathComponent
        }

        return FileMetadataLayer(
            title: book.title,
            author: book.author,
            narrator: book.narrator,
            series: book.series,
            seriesNumber: book.seriesNumber,
            year: book.publishedYear,
            publisher: book.publisher,
            genres: book.genres,
            description: book.description,
            duration: book.duration,
            isbn: book.isbn,
            asin: book.asin,
            fileName: fileName,
            folderName: folderName
        )
    }

    func updateUserMetadata(
        bookId: String,
        title: String? = nil,
        author: String? = nil,
        narrator: String? = nil,
        description: String? = nil,
        series: String? = nil,
        seriesNumber: Int? = nil,
        genres: [String]? = nil,
        notes: String = ""
    ) throws {
        try playbackStateManager.saveMetadataOverride(
            bookId: bookId,
            title: title,
            author: author,
            narrator: narrator,
            description: description,
            series: series,
            seriesNumber: seriesNumber,
            genres: genres ?? [],
            notes: notes
        )
        AppLogger.network.debug(
            "Metadata overrides updated bookId=\(DiagnosticLogSanitizer.identifier(for: bookId))"
        )
    }

    func clearUserMetadata(for bookId: String) throws {
        try playbackStateManager.deleteMetadataOverride(for: bookId)
        AppLogger.network.debug(
            "Metadata overrides cleared bookId=\(DiagnosticLogSanitizer.identifier(for: bookId))"
        )
    }

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

    func markServerMetadataStale(for bookId: String) {
        AppLogger.network.debug(
            "Marked server metadata stale bookId=\(DiagnosticLogSanitizer.identifier(for: bookId))"
        )
    }

    func refreshServerMetadata(for book: Book) async throws -> FileMetadataLayer {
        switch book.source {
        case .audiobookshelf:
            AppLogger.network.debug("Refreshing Audiobookshelf metadata bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId))")
            return extractServerMetadata(from: book)

        case .plex:
            AppLogger.network.debug("Refreshing Plex metadata bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId))")
            return extractServerMetadata(from: book)

        case .jellyfin, .emby:
            AppLogger.network.debug("Refreshing Jellyfin/Emby metadata bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId))")
            return extractServerMetadata(from: book)

        case .local, .smb, .webdav, .booklore, .realdebrid, .komga, .kavita, .opds, .storyteller, .bookOrbit, .silo, .torbox:
            AppLogger.network.debug("Local source - no server refresh bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId))")
            return extractServerMetadata(from: book)
        }
    }

    func hasUserOverrides(for bookId: String) throws -> Bool {
        let overrides = try playbackStateManager.loadMetadataOverride(for: bookId)
        return overrides.customTitle != nil || overrides.customAuthor != nil || overrides.customNarrator != nil
            || overrides.customDescription != nil || overrides.customSeries != nil || overrides.customSeriesNumber != nil
            || !overrides.customGenres.isEmpty || !overrides.customNotes.isEmpty
    }
}

struct ResolvedMetadata {
    let embedded: FileMetadataLayer?

    let server: FileMetadataLayer?

    let userOverrides: MetadataOverride?

    var resolvedTitle: String {
        if let override = userOverrides?.customTitle { return override }
        if let server = server?.title { return server }
        if let embedded = embedded?.title { return embedded }
        return "Unknown"
    }

    var resolvedAuthor: String? {
        if let override = userOverrides?.customAuthor { return override }
        if let server = server?.author { return server }
        if let embedded = embedded?.author { return embedded }
        return nil
    }

    var resolvedNarrator: String? {
        if let override = userOverrides?.customNarrator { return override }
        if let server = server?.narrator { return server }
        if let embedded = embedded?.narrator { return embedded }
        return nil
    }

    var resolvedDescription: String? {
        if let override = userOverrides?.customDescription { return override }
        if let server = server?.description { return server }
        if let embedded = embedded?.description { return embedded }
        return nil
    }

    var resolvedSeries: String? {
        if let override = userOverrides?.customSeries { return override }
        if let server = server?.series { return server }
        if let embedded = embedded?.series { return embedded }
        return nil
    }

    var resolvedSeriesNumber: Int? {
        if let override = userOverrides?.customSeriesNumber { return override }
        if let server = server?.seriesNumber { return server }
        if let embedded = embedded?.seriesNumber { return embedded }
        return nil
    }

    var resolvedGenres: [String] {
        if let customGenres = userOverrides?.customGenres, !customGenres.isEmpty {
            return customGenres
        }
        if let serverGenres = server?.genres { return serverGenres }
        if let embeddedGenres = embedded?.genres { return embeddedGenres }
        return []
    }
}
