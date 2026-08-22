import AVFoundation
import Foundation
import Speech

enum AudiobookClipError: LocalizedError {
    case downloadRequired
    case invalidRange
    case clipTooLong
    case noAudioTracks
    case exportFailed
    case speechAuthorizationDenied
    case onDeviceTranscriptionUnavailable
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .downloadRequired:
            return "Download this book before creating or exporting clips."
        case .invalidRange:
            return "The clip range is invalid."
        case .clipTooLong:
            return "Clips are limited to one hour."
        case .noAudioTracks:
            return "No playable local audio files were found for this book."
        case .exportFailed:
            return "The clip couldn't be exported."
        case .speechAuthorizationDenied:
            return "Speech Recognition permission is required to transcribe clips."
        case .onDeviceTranscriptionUnavailable:
            return "On-device transcription isn't available for this language or device."
        case .transcriptionFailed:
            return "The clip couldn't be transcribed."
        }
    }
}

@MainActor
final class AudiobookClipService {
    static let shared = AudiobookClipService()

    private let store = AudiobookClipStore.shared

    private init() {}

    func clip(bookId: String, bookmarkId: String) -> AudiobookClip? {
        store.clip(bookId: bookId, clipId: bookmarkId)
    }

    func clips(bookId: String) -> [AudiobookClip] {
        store.loadClips(bookId: bookId)
    }

    @discardableResult
    func saveClip(bookId: String, bookmarkId: String, startTime: TimeInterval, endTime: TimeInterval) -> AudiobookClip {
        let existing = store.clip(bookId: bookId, clipId: bookmarkId)
        let clip = AudiobookClip(
            id: bookmarkId,
            bookId: bookId,
            bookmarkId: bookmarkId,
            startTime: startTime,
            endTime: endTime,
            createdAt: existing?.createdAt ?? Date(),
            transcript: existing?.transcript
        )
        store.upsertClip(clip)
        return clip
    }

    func deleteClip(bookId: String, clipId: String) {
        store.deleteClip(bookId: bookId, clipId: clipId)
    }

    func exportClip(_ clip: AudiobookClip, for book: Book, title: String) async throws -> URL {
        try validate(clip)
        let segments = try await localSegments(for: book)
        let composition = try await composition(for: clip, segments: segments)
        let outputURL = Self.makeTemporaryURL(
            prefix: sanitizedFileNameComponent(book.title),
            suffix: sanitizedFileNameComponent(title),
            ext: "m4a"
        )
        try? FileManager.default.removeItem(at: outputURL)

        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudiobookClipError.exportFailed
        }
        exporter.outputURL = outputURL
        exporter.outputFileType = .m4a
        try await export(exporter)
        return outputURL
    }

    func transcribeClip(_ clip: AudiobookClip, for book: Book, title: String) async throws -> String {
        let exportURL = try await exportClip(clip, for: book, title: title)
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let status = await requestSpeechAuthorization()
        guard status == .authorized else {
            throw AudiobookClipError.speechAuthorizationDenied
        }

        let recognizer = speechRecognizer(for: book)
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw AudiobookClipError.onDeviceTranscriptionUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: exportURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }

        let transcript = try await transcribe(request: request, recognizer: recognizer)
        let updated = AudiobookClip(
            id: clip.id,
            bookId: clip.bookId,
            bookmarkId: clip.bookmarkId,
            startTime: clip.startTime,
            endTime: clip.endTime,
            createdAt: clip.createdAt,
            transcript: transcript
        )
        store.upsertClip(updated)
        return transcript
    }

    private func validate(_ clip: AudiobookClip) throws {
        guard clip.endTime > clip.startTime else {
            throw AudiobookClipError.invalidRange
        }
        guard clip.duration <= 3600 else {
            throw AudiobookClipError.clipTooLong
        }
    }

    private func localSegments(for book: Book) async throws -> [LocalSegment] {
        guard let localFiles = LocalStorageManager.shared.localAudiobookFilesIfExists(for: book),
            !localFiles.isEmpty
        else {
            throw AudiobookClipError.downloadRequired
        }

        var segments: [LocalSegment] = []
        var runningOffset: TimeInterval = 0

        for (index, url) in localFiles.enumerated() {
            let hintedDuration =
                if let tracks = book.audioTracks,
                    index < tracks.count,
                    tracks[index].duration > 0
                {
                    tracks[index].duration
                } else {
                    0.0
                }
            let duration = try await resolvedDuration(for: url, fallback: hintedDuration)
            segments.append(LocalSegment(url: url, startOffset: runningOffset, duration: duration))
            runningOffset += duration
        }

        guard !segments.isEmpty else {
            throw AudiobookClipError.noAudioTracks
        }
        return segments
    }

    private func resolvedDuration(for url: URL, fallback: TimeInterval) async throws -> TimeInterval {
        if fallback > 0 {
            return fallback
        }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw AudiobookClipError.noAudioTracks
        }
        return duration
    }

    private func composition(for clip: AudiobookClip, segments: [LocalSegment]) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard
            let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
        else {
            throw AudiobookClipError.exportFailed
        }

        var insertionTime = CMTime.zero

        for segment in segments {
            let segmentEnd = segment.startOffset + segment.duration
            let overlapStart = max(segment.startOffset, clip.startTime)
            let overlapEnd = min(segmentEnd, clip.endTime)

            guard overlapEnd > overlapStart else { continue }

            let asset = AVURLAsset(url: segment.url)
            let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = sourceTracks.first else {
                continue
            }

            let localStart = overlapStart - segment.startOffset
            let rangeDuration = overlapEnd - overlapStart
            let timeRange = CMTimeRange(
                start: CMTime(seconds: localStart, preferredTimescale: 600),
                duration: CMTime(seconds: rangeDuration, preferredTimescale: 600)
            )
            try compositionTrack.insertTimeRange(timeRange, of: sourceTrack, at: insertionTime)
            insertionTime = insertionTime + timeRange.duration
        }

        guard insertionTime.seconds > 0 else {
            throw AudiobookClipError.noAudioTracks
        }

        return composition
    }

    private func export(_ exporter: AVAssetExportSession) async throws {
        let exporterBox = NonSendableBox(exporter)
        try await withCheckedThrowingContinuation { continuation in
            exporter.exportAsynchronously {
                switch exporterBox.value.status {
                case .completed:
                    continuation.resume()
                case .failed, .cancelled:
                    continuation.resume(throwing: exporterBox.value.error ?? AudiobookClipError.exportFailed)
                default:
                    continuation.resume(throwing: AudiobookClipError.exportFailed)
                }
            }
        }
    }

    private func speechRecognizer(for book: Book) -> SFSpeechRecognizer? {
        if let language = book.language, !language.isEmpty,
            let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
        {
            return recognizer
        }
        return SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer()
    }

    private func transcribe(request: SFSpeechURLRecognitionRequest, recognizer: SFSpeechRecognizer) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    task?.cancel()
                    continuation.resume(returning: result.bestTranscription.formattedString)
                    return
                }

                if let error {
                    task?.cancel()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private static func makeTemporaryURL(prefix: String, suffix: String, ext: String) -> URL {
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let safePrefix = prefix.isEmpty ? "enve" : prefix
        let safeSuffix = suffix.isEmpty ? "clip" : suffix
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safePrefix)-\(safeSuffix)-\(timestamp)")
            .appendingPathExtension(ext)
    }
}

private struct LocalSegment {
    let url: URL
    let startOffset: TimeInterval
    let duration: TimeInterval
}

private func sanitizedFileNameComponent(_ value: String) -> String {
    let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let cleaned = folded.unicodeScalars.map { scalar -> Character in
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9":
            return Character(scalar)
        default:
            return "-"
        }
    }
    let collapsed = String(cleaned)
        .replacingOccurrences(of: "-{2,}", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return collapsed.lowercased()
}
