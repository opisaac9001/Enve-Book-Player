import Foundation
import Logging

@MainActor
final class BookTranscriptStore {
    static let shared = BookTranscriptStore()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadTranscript(bookStableId: String) -> BookTranscript? {
        let directory = transcriptDirectory(bookStableId: bookStableId)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let segmentsURL = directory.appendingPathComponent("segments.json")

        guard let manifestData = try? Data(contentsOf: manifestURL),
            let segmentData = try? Data(contentsOf: segmentsURL),
            let manifest = try? decoder.decode(BookTranscriptManifest.self, from: manifestData),
            let segments = try? decoder.decode([TranscriptSegment].self, from: segmentData)
        else {
            return nil
        }

        return BookTranscript(manifest: manifest, segments: TranscriptSegmentNormalizer.normalize(segments))
    }

    func manifest(bookStableId: String) -> BookTranscriptManifest? {
        guard let data = try? Data(contentsOf: transcriptDirectory(bookStableId: bookStableId).appendingPathComponent("manifest.json"))
        else {
            return nil
        }
        return try? decoder.decode(BookTranscriptManifest.self, from: data)
    }

    func saveTranscript(
        bookStableId: String,
        localeIdentifier: String,
        duration: TimeInterval,
        fingerprint: TranscriptSourceFingerprint,
        segments: [TranscriptSegment]
    ) throws {
        let now = Date()
        let manifest = BookTranscriptManifest(
            bookStableId: bookStableId,
            status: .ready,
            localeIdentifier: localeIdentifier,
            createdAt: manifest(bookStableId: bookStableId)?.createdAt ?? now,
            updatedAt: now,
            duration: duration,
            segmentCount: segments.count,
            sourceFingerprint: fingerprint,
            failureMessage: nil
        )
        try write(manifest: manifest, segments: TranscriptSegmentNormalizer.normalize(segments), bookStableId: bookStableId)
    }

    func savePartialTranscript(
        bookStableId: String,
        localeIdentifier: String,
        duration: TimeInterval,
        fingerprint: TranscriptSourceFingerprint,
        segments: [TranscriptSegment]
    ) throws {
        let now = Date()
        let existing = loadTranscript(bookStableId: bookStableId)
        let mergedSegments = Self.mergedSegments(existing?.segments ?? [], segments)
        let manifest = BookTranscriptManifest(
            bookStableId: bookStableId,
            status: .generating,
            localeIdentifier: localeIdentifier,
            createdAt: existing?.manifest.createdAt ?? now,
            updatedAt: now,
            duration: duration,
            segmentCount: mergedSegments.count,
            sourceFingerprint: fingerprint,
            failureMessage: nil
        )
        try write(manifest: manifest, segments: mergedSegments, bookStableId: bookStableId)
    }

    func markGenerating(bookStableId: String, localeIdentifier: String, duration: TimeInterval, fingerprint: TranscriptSourceFingerprint) {
        let now = Date()
        let manifest = BookTranscriptManifest(
            bookStableId: bookStableId,
            status: .generating,
            localeIdentifier: localeIdentifier,
            createdAt: manifest(bookStableId: bookStableId)?.createdAt ?? now,
            updatedAt: now,
            duration: duration,
            segmentCount: loadTranscript(bookStableId: bookStableId)?.segments.count ?? 0,
            sourceFingerprint: fingerprint,
            failureMessage: nil
        )
        try? write(manifest: manifest, segments: loadTranscript(bookStableId: bookStableId)?.segments ?? [], bookStableId: bookStableId)
    }

    func markFailed(bookStableId: String, message: String) {
        guard var existing = manifest(bookStableId: bookStableId) else { return }
        existing.status = .failed
        existing.updatedAt = Date()
        existing.failureMessage = message
        try? write(manifest: existing, segments: loadTranscript(bookStableId: bookStableId)?.segments ?? [], bookStableId: bookStableId)
    }

    func clear(bookStableId: String) {
        try? fileManager.removeItem(at: transcriptDirectory(bookStableId: bookStableId))
    }

    func status(for book: Book, currentFingerprint: TranscriptSourceFingerprint?) -> BookTranscriptStatus {
        guard let manifest = manifest(bookStableId: book.stableId) else { return .missing }
        if manifest.status == .ready,
            let currentFingerprint,
            let existing = manifest.sourceFingerprint,
            existing != currentFingerprint
        {
            return .stale
        }
        return manifest.status
    }

    private func write(manifest: BookTranscriptManifest, segments: [TranscriptSegment], bookStableId: String) throws {
        let directory = transcriptDirectory(bookStableId: bookStableId)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try encoder.encode(segments).write(to: directory.appendingPathComponent("segments.json"), options: .atomic)
        AppLogger.general.info("Saved \(segments.count) transcript segments for \(bookStableId)")
    }

    private static func mergedSegments(_ existing: [TranscriptSegment], _ newSegments: [TranscriptSegment]) -> [TranscriptSegment] {
        TranscriptSegmentNormalizer.normalize(existing + newSegments)
    }

    private func transcriptDirectory(bookStableId: String) -> URL {
        rootDirectory.appendingPathComponent(Self.safeComponent(bookStableId), isDirectory: true)
    }

    private var rootDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Enve/BookIntelligence/Transcripts", isDirectory: true)
    }

    nonisolated static func safeComponent(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
    }
}
