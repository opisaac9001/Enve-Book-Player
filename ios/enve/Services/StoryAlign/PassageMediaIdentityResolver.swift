import CryptoKit
import Foundation

/// Establishes strong media identity by content digest. A cached digest is reused only while the file's
/// size and modification date still match the association recorded when it was hashed.
@MainActor
final class PassageMediaIdentityResolver {
    private nonisolated struct Association: Codable, Equatable, Sendable {
        let size: Int64
        let modified: TimeInterval
        let digest: String
    }

    private let cacheURL: URL
    private var associations: [String: Association]?
    private var inFlight: [String: (attributes: Association, task: Task<String, Error>)] = [:]
    private var isRetired = false
    private let streamNamespace = UUID().uuidString

    init(cacheURL: URL) {
        self.cacheURL = cacheURL
    }

    func identity(ebookStableId: String, audiobookStableId: String, epubURL: URL, audioURLs: [URL], streamSession: String? = nil) async throws -> PassageMediaIdentity {
        let reading = try await digest(of: epubURL)
        var tracks: [String] = []
        for url in audioURLs {
            try Task.checkCancellation()
            if let revision = streamRevision(url, session: streamSession) { tracks.append(revision) }
            else { tracks.append(try await digest(of: url)) }
        }
        return PassageMediaIdentity(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId, readingRevision: reading, trackRevisions: tracks)
    }

    /// The cached identity when every file still matches its recorded association; never hashes.
    func cachedIdentity(ebookStableId: String, audiobookStableId: String, epubURL: URL, audioURLs: [URL], streamSession: String? = nil) async -> PassageMediaIdentity? {
        await loadIfNeeded()
        func cached(_ url: URL) -> String? {
            guard let current = Self.attributes(url), let stored = associations?[Self.key(url)],
                stored.size == current.size, stored.modified == current.modified
            else { return nil }
            return stored.digest
        }
        guard let reading = cached(epubURL) else { return nil }
        let tracks = audioURLs.compactMap { streamRevision($0, session: streamSession) ?? cached($0) }
        guard tracks.count == audioURLs.count else { return nil }
        return PassageMediaIdentity(ebookStableId: ebookStableId, audiobookStableId: audiobookStableId, readingRevision: reading, trackRevisions: tracks)
    }

    private func streamRevision(_ url: URL, session: String?) -> String? {
        guard !url.isFileURL, let session else { return nil }
        return SHA256.hash(data: Data("\(streamNamespace)\u{0}\(session)\u{0}\(url.absoluteString)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    func retire() {
        isRetired = true
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
    }

    func digest(of url: URL) async throws -> String {
        await loadIfNeeded()
        let path = Self.key(url)
        guard let attributes = Self.attributes(url) else { throw CocoaError(.fileReadNoSuchFile) }
        if let stored = associations?[path], stored.size == attributes.size, stored.modified == attributes.modified {
            return stored.digest
        }
        let task: Task<String, Error>
        if let running = inFlight[path], running.attributes == attributes {
            task = running.task
        } else {
            // A replaced file supersedes identity work started for its previous revision.
            inFlight[path]?.task.cancel()
            task = Task.detached(priority: .utility) { try Self.sha256(url) }
            inFlight[path] = (attributes, task)
        }
        let digest = try await task.value
        if inFlight[path]?.attributes == attributes { inFlight[path] = nil }
        guard !isRetired, Self.attributes(url) == attributes else { throw CancellationError() }
        associations?[path] = Association(size: attributes.size, modified: attributes.modified, digest: digest)
        await save()
        return digest
    }

    private func loadIfNeeded() async {
        guard associations == nil else { return }
        let url = cacheURL
        let loaded = await Task.detached(priority: .userInitiated) { () -> [String: Association] in
            guard let data = try? Data(contentsOf: url) else { return [:] }
            return (try? JSONDecoder().decode([String: Association].self, from: data)) ?? [:]
        }.value
        if associations == nil { associations = loaded }
    }

    private func save() async {
        guard let associations, !isRetired else { return }
        let url = cacheURL
        await Task.detached(priority: .utility) {
            let home = NSHomeDirectory()
            let current = associations.filter { FileManager.default.fileExists(atPath: $0.key.hasPrefix("~/") ? home + $0.key.dropFirst() : $0.key) }
            guard let data = try? JSONEncoder().encode(current) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }.value
    }

    /// Home-relative, because the app's data container path changes when the app is reinstalled or updated.
    private nonisolated static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // URL resource values are cached per URL instance; file attributes reflect a replaced file immediately.
    private nonisolated static func attributes(_ url: URL) -> Association? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return Association(size: size, modified: modified, digest: "")
    }

    nonisolated static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
