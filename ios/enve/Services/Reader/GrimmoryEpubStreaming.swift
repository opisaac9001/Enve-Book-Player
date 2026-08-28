import Foundation
#if canImport(ReadiumShared)
@preconcurrency import ReadiumShared
#endif

enum GrimmoryEpubStreaming {
    static func isEligible(_ book: Book) -> Bool {
        book.source == .booklore
            && book.mediaType == .ebook
            && !book.isComic
            && !book.isReadAloudBook
            && book.epub3Features?.hasMediaOverlay != true
            && (book.ebookFormat == nil || book.ebookFormat?.caseInsensitiveCompare("epub") == .orderedSame)
    }

    static func makeSession(
        for book: Book,
        providerResolver: any LibraryProviderResolving
    ) async throws -> GrimmoryEpubStreamingSession {
        guard let provider = providerResolver.provider(for: book) as? BookloreProvider else {
            throw ProviderError.notImplemented
        }
        return try await provider.makeEpubStreamingSession(for: book)
    }
}

final class GrimmoryEpubStreamingSession: @unchecked Sendable {
    struct Entry {
        let path: String
        let mediaType: String?
        let size: UInt64
    }

    nonisolated let entries: [Entry]
    nonisolated let sizesByPath: [String: UInt64]
    private nonisolated let entriesByPath: [String: Entry]
    private nonisolated let cacheRoot: URL
    private nonisolated let fetchRemote: @Sendable (String) async throws -> Data

    nonisolated init(
        entries: [Entry],
        cacheRoot: URL,
        fetchRemote: @escaping @Sendable (String) async throws -> Data
    ) {
        self.entries = entries
        self.cacheRoot = cacheRoot
        self.fetchRemote = fetchRemote
        var byPath: [String: Entry] = [:]
        var sizes: [String: UInt64] = [:]
        for entry in entries {
            byPath[entry.path] = entry
            sizes[entry.path] = entry.size
        }
        entriesByPath = byPath
        sizesByPath = sizes
    }

    nonisolated func entry(atPath path: String) -> Entry? {
        entriesByPath[path]
    }

    nonisolated func resourceData(atPath path: String) async throws -> Data {
        guard entriesByPath[path] != nil, let cacheURL = cacheURL(forPath: path) else {
            throw ProviderError.invalidResponse
        }
        if let cached = try? Data(contentsOf: cacheURL) {
            return cached
        }
        let data = try await fetchRemote(path)
        try Task.checkCancellation()
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
        return data
    }

    nonisolated func prefetchAllResources() async {
        for entry in entries {
            guard !Task.isCancelled else { return }
            if let cacheURL = cacheURL(forPath: entry.path),
                FileManager.default.fileExists(atPath: cacheURL.path)
            {
                continue
            }
            _ = try? await resourceData(atPath: entry.path)
        }
    }

    private nonisolated func cacheURL(forPath path: String) -> URL? {
        let fileURL = cacheRoot.appendingPathComponent(path, isDirectory: false)
        guard fileURL.standardizedFileURL.path.hasPrefix(cacheRoot.standardizedFileURL.path + "/") else {
            return nil
        }
        return fileURL
    }
}

#if canImport(ReadiumShared)
private nonisolated final class GrimmoryStreamedResource: TransformingResource, @unchecked Sendable {
    private nonisolated let estimatedByteLength: UInt64?

    nonisolated init(
        estimatedByteLength: UInt64,
        makeData: @escaping @Sendable () async -> ReadResult<Data>
    ) {
        self.estimatedByteLength = estimatedByteLength > 0 ? estimatedByteLength : nil
        super.init(DataResource(sourceURL: nil, makeData: makeData), transform: { $0 })
    }

    nonisolated override func estimatedLength() async -> ReadResult<UInt64?> {
        .success(estimatedByteLength)
    }
}

final class StreamedGrimmoryEpubContainer: Container, @unchecked Sendable {
    nonisolated let sourceURL: AbsoluteURL? = nil
    nonisolated let entries: Set<AnyURL>
    private nonisolated let pathsByURL: [RelativeURL: String]
    private nonisolated let session: GrimmoryEpubStreamingSession

    nonisolated init(session: GrimmoryEpubStreamingSession) {
        self.session = session
        var paths: [RelativeURL: String] = [:]
        for entry in session.entries {
            if let url = RelativeURL(path: entry.path)?.normalized {
                paths[url] = entry.path
            }
        }
        pathsByURL = paths
        entries = Set(paths.keys.map(\.anyURL))
    }

    nonisolated subscript(url: any URLConvertible) -> (any Resource)? {
        guard let relative = url.anyURL.relativeURL?.normalized,
            let path = pathsByURL[relative],
            let entry = session.entry(atPath: path)
        else {
            return nil
        }
        let session = session
        return GrimmoryStreamedResource(estimatedByteLength: entry.size) {
            do {
                return try await .success(session.resourceData(atPath: path))
            } catch {
                return .failure(.access(.other(error)))
            }
        }
    }
}
#endif
