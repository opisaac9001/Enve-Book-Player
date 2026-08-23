import Foundation
import Logging

@MainActor
final class EbookContextStore {
    static let shared = EbookContextStore()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadContext(bookStableId: String) -> EbookContext? {
        let directory = contextDirectory(bookStableId: bookStableId)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let chunksURL = directory.appendingPathComponent("chunks.json")

        guard let manifestData = try? Data(contentsOf: manifestURL),
            let chunkData = try? Data(contentsOf: chunksURL),
            let manifest = try? decoder.decode(EbookContextManifest.self, from: manifestData),
            let chunks = try? decoder.decode([EbookContextChunk].self, from: chunkData)
        else {
            return nil
        }

        return EbookContext(manifest: manifest, chunks: chunks.sorted { $0.startProgress < $1.startProgress })
    }

    func manifest(bookStableId: String) -> EbookContextManifest? {
        guard let data = try? Data(contentsOf: contextDirectory(bookStableId: bookStableId).appendingPathComponent("manifest.json")) else {
            return nil
        }
        return try? decoder.decode(EbookContextManifest.self, from: data)
    }

    func saveContext(bookStableId: String, chunks: [EbookContextChunk]) throws {
        let now = Date()
        let manifest = EbookContextManifest(
            bookStableId: bookStableId,
            status: .ready,
            createdAt: manifest(bookStableId: bookStableId)?.createdAt ?? now,
            updatedAt: now,
            chunkCount: chunks.count,
            failureMessage: nil
        )
        try write(manifest: manifest, chunks: chunks.sorted { $0.startProgress < $1.startProgress }, bookStableId: bookStableId)
    }

    func markGenerating(bookStableId: String) {
        let now = Date()
        let existing = loadContext(bookStableId: bookStableId)
        let manifest = EbookContextManifest(
            bookStableId: bookStableId,
            status: .generating,
            createdAt: existing?.manifest.createdAt ?? now,
            updatedAt: now,
            chunkCount: existing?.chunks.count ?? 0,
            failureMessage: nil
        )
        try? write(manifest: manifest, chunks: existing?.chunks ?? [], bookStableId: bookStableId)
    }

    func markFailed(bookStableId: String, message: String) {
        let now = Date()
        let existing = loadContext(bookStableId: bookStableId)
        let manifest = EbookContextManifest(
            bookStableId: bookStableId,
            status: .failed,
            createdAt: existing?.manifest.createdAt ?? now,
            updatedAt: now,
            chunkCount: existing?.chunks.count ?? 0,
            failureMessage: message
        )
        try? write(manifest: manifest, chunks: existing?.chunks ?? [], bookStableId: bookStableId)
    }

    func clear(bookStableId: String) {
        try? fileManager.removeItem(at: contextDirectory(bookStableId: bookStableId))
    }

    private func write(manifest: EbookContextManifest, chunks: [EbookContextChunk], bookStableId: String) throws {
        let directory = contextDirectory(bookStableId: bookStableId)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try encoder.encode(chunks).write(to: directory.appendingPathComponent("chunks.json"), options: .atomic)
        AppLogger.general.info("Saved \(chunks.count) ebook context chunks for \(bookStableId)")
    }

    private func contextDirectory(bookStableId: String) -> URL {
        rootDirectory.appendingPathComponent(BookTranscriptStore.safeComponent(bookStableId), isDirectory: true)
    }

    private var rootDirectory: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Enve/BookIntelligence/EbookContexts", isDirectory: true)
    }
}
