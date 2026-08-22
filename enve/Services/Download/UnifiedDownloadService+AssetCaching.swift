import AVFoundation
import Foundation
import Logging
import UIKit

extension UnifiedDownloadService {
    func cacheAssetsForOffline(book: Book) async {
        let bookId = book.downloadKey
        let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)

        if let coverURL = book.coverURL {
            do {
                if !DiskImageCache.shared.hasImage(for: coverURL) {
                    let coverData: Data?
                    if book.source == .booklore,
                        let provider = providerConnections.provider(for: book) as? BookloreProvider
                    {
                        let (fetched, _) = try await provider.fetchImageData(url: coverURL)
                        coverData = UIImage(data: fetched) != nil ? fetched : nil
                    } else {
                        let config = URLSessionConfiguration.default
                        config.timeoutIntervalForRequest = 15
                        let session = URLSession(configuration: config)
                        let (fetched, _) = try await session.data(from: coverURL)
                        coverData = fetched
                    }
                    if let data = coverData, let image = UIImage(data: data) {
                        DiskImageCache.shared.save(image, for: coverURL)
                        _ = try? LocalStorageManager.shared.saveCoverOverride(for: bookId, imageData: data)
                        AppLogger.network.debug("[Download] Cover cached bookDiagnosticID=\(diagnosticID)")
                    }
                } else {
                    if let img = await DiskImageCache.shared.image(for: coverURL),
                        let data = img.jpegData(compressionQuality: 0.85)
                    {
                        _ = try? LocalStorageManager.shared.saveCoverOverride(for: bookId, imageData: data)
                    }
                    AppLogger.network.debug("[Download] Cover promoted bookDiagnosticID=\(diagnosticID)")
                }
            } catch {
                AppLogger.network.error(
                    "Failed to cache cover bookDiagnosticID=\(diagnosticID): \(error.localizedDescription)"
                )
            }
        }

        do {
            let metadata = OfflineBookMetadata(
                id: book.id,
                stableId: book.stableId,
                title: book.title,
                author: book.author,
                narrator: book.narrator,
                duration: book.duration,
                chapters: book.chapters,
                audioTracks: book.audioTracks,
                coverURLString: book.coverURL?.absoluteString,
                source: book.source
            )
            try LocalStorageManager.shared.saveMetadataOverride(metadata, for: bookId)
            AppLogger.network.debug("Metadata saved for offline use bookDiagnosticID=\(diagnosticID)")
        } catch {
            AppLogger.network.error(
                "Failed to save metadata bookDiagnosticID=\(diagnosticID): \(error.localizedDescription)"
            )
        }

        await refreshOfflineMetadataFromDownloadedFiles(book: book, bookId: bookId)
    }

    func refreshOfflineMetadataFromDownloadedFiles(book: Book, bookId: String) async {
        let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)

        #if os(iOS)
        guard let localFiles = LocalStorageManager.shared.localAudiobookFilesIfExists(for: book),
            let primaryFile = localFiles.first,
            !localFiles.isEmpty
        else {
            return
        }

        do {
            let primaryMetadata = try await LocalLibraryService.shared.loadMetadataForDownloadedAudio(at: primaryFile.path)

            var sessionFallbackDurations: [Int: TimeInterval] = [:]
            if book.source == .booklore,
                let provider = providerConnections.provider(for: book) as? BookloreProvider,
                let session = try? await provider.startPlaybackSession(for: book)
            {
                for track in session.audioTracks {
                    let duration = max(track.duration, 0)
                    if duration > 0 {
                        sessionFallbackDurations[track.index] = duration
                    }
                }
            }

            var rebuiltTracks: [AudioTrack] = []
            rebuiltTracks.reserveCapacity(localFiles.count)

            var runningOffset: TimeInterval = 0
            for (index, fileURL) in localFiles.enumerated() {
                let fileMetadata = try? await LocalLibraryService.shared.loadMetadataForDownloadedAudio(at: fileURL.path)
                let fallbackDuration =
                    (book.audioTracks != nil && index < (book.audioTracks?.count ?? 0))
                    ? (book.audioTracks?[index].duration ?? 0)
                    : 0
                let sessionDuration = sessionFallbackDurations[index] ?? 0
                let probedDuration = localAudioDuration(for: fileURL) ?? 0
                let duration = max(probedDuration, fileMetadata?.duration ?? 0, fallbackDuration, sessionDuration)
                let title =
                    fileMetadata?.title.isEmpty == false
                    ? fileMetadata?.title
                    : fileURL.deletingPathExtension().lastPathComponent

                rebuiltTracks.append(
                    AudioTrack(
                        id: "\(bookId)_track_\(index)",
                        index: index,
                        title: title,
                        filePath: fileURL.path,
                        contentUrl: nil,
                        duration: duration,
                        startOffset: runningOffset,
                        format: fileURL.pathExtension
                    )
                )
                runningOffset += duration
            }

            let synthesizedTrackChapters: [Chapter] = rebuiltTracks.enumerated().map { index, track in
                Chapter(
                    id: "offline_track_\(index)",
                    start: track.startOffset,
                    end: track.startOffset + max(track.duration, 0),
                    title: track.title ?? "Chapter \(index + 1)",
                    index: index
                )
            }

            let embeddedChapters = primaryMetadata.chapters?.enumerated().map { index, chapter in
                Chapter(
                    id: chapter.id,
                    start: chapter.startTime,
                    end: chapter.endTime,
                    title: chapter.title,
                    index: index
                )
            }

            let resolvedDuration: TimeInterval = {
                let summed = rebuiltTracks.reduce(0) { $0 + max($1.duration, 0) }
                if summed > 0 { return summed }
                if let d = book.duration, d > 0 { return d }
                return primaryMetadata.duration ?? 0
            }()

            let resolvedChapters: [Chapter]? = {
                if let existing = book.chapters, existing.count > 1 { return existing }
                if let embeddedChapters, !embeddedChapters.isEmpty { return embeddedChapters }
                return synthesizedTrackChapters.isEmpty ? nil : synthesizedTrackChapters
            }()

            let metadata = OfflineBookMetadata(
                id: book.id,
                stableId: book.stableId,
                title: book.title,
                author: primaryMetadata.author ?? book.author,
                narrator: primaryMetadata.narrator ?? book.narrator,
                duration: resolvedDuration > 0 ? resolvedDuration : nil,
                chapters: resolvedChapters,
                audioTracks: rebuiltTracks.isEmpty ? book.audioTracks : rebuiltTracks,
                coverURLString: primaryMetadata.coverImagePath ?? book.thumb,
                source: book.source
            )

            try LocalStorageManager.shared.saveMetadataOverride(metadata, for: bookId)
            AppLogger.network.debug("Refreshed offline metadata bookDiagnosticID=\(diagnosticID)")
        } catch {
            AppLogger.network.error(
                "Failed to refresh downloaded metadata bookDiagnosticID=\(diagnosticID): \(error.localizedDescription)"
            )
        }
        #endif
    }

    private func localAudioDuration(for fileURL: URL) -> TimeInterval? {
        guard let player = try? AVAudioPlayer(contentsOf: fileURL) else { return nil }
        let seconds = player.duration
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}
