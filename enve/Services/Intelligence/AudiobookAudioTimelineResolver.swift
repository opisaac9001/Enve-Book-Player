import AVFoundation
import Foundation

enum AudiobookTimelineError: LocalizedError {
    case downloadRequired
    case noPlayableAudio

    var errorDescription: String? {
        switch self {
        case .downloadRequired:
            return "Download this audiobook before using Enve Librarian."
        case .noPlayableAudio:
            return "No playable local audio files were found for this audiobook."
        }
    }
}

@MainActor
final class AudiobookAudioTimelineResolver {
    static let shared = AudiobookAudioTimelineResolver()

    private init() {}

    func localTracks(for book: Book) async throws -> [AudioTrackInfo] {
        guard let localFiles = LocalStorageManager.shared.localAudiobookFilesIfExists(for: book),
            !localFiles.isEmpty
        else {
            throw AudiobookTimelineError.downloadRequired
        }

        var tracks: [AudioTrackInfo] = []
        var runningOffset: TimeInterval = 0

        for (index, fileURL) in localFiles.enumerated() {
            let duration = try await resolvedDuration(for: fileURL, book: book, index: index, fileCount: localFiles.count)
            tracks.append(
                AudioTrackInfo(
                    index: index,
                    startOffset: runningOffset,
                    duration: duration,
                    contentUrl: fileURL.absoluteString,
                    mimeType: mimeType(for: fileURL)
                )
            )
            runningOffset += duration
        }

        guard !tracks.isEmpty else {
            throw AudiobookTimelineError.noPlayableAudio
        }

        return tracks
    }

    func sourceFingerprint(for book: Book, localeIdentifier: String) async throws -> TranscriptSourceFingerprint {
        let tracks = try await localTracks(for: book)
        let files = tracks.compactMap { track -> TranscriptSourceFile? in
            guard let url = URL(string: track.contentUrl), url.isFileURL else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return TranscriptSourceFile(
                path: url.path,
                byteCount: Int64(values?.fileSize ?? 0),
                modificationTime: values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            )
        }

        return TranscriptSourceFingerprint(
            version: 1,
            localeIdentifier: localeIdentifier,
            duration: tracks.totalDuration,
            files: files
        )
    }

    private func resolvedDuration(for fileURL: URL, book: Book, index: Int, fileCount: Int) async throws -> TimeInterval {
        if let tracks = book.audioTracks,
            index < tracks.count,
            tracks[index].duration > 0
        {
            return tracks[index].duration
        }

        if fileCount == 1, let duration = book.duration, duration > 0 {
            return duration
        }

        let asset = AVURLAsset(url: fileURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw AudiobookTimelineError.noPlayableAudio
        }
        return duration
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp3": return "audio/mpeg"
        case "m4a", "m4b", "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        case "opus": return "audio/opus"
        case "wav": return "audio/wav"
        default: return "audio/mpeg"
        }
    }
}
