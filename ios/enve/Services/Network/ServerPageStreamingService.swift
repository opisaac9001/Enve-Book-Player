import Foundation

final class ServerPageStreamingService: @unchecked Sendable {
    static let shared = ServerPageStreamingService()

    private let fileManager = FileManager.default
    private var sources: [String: StreamSource] = [:]
    private var streamIDsByBook: [String: String] = [:]
    private var fullCacheTasks: [String: Task<Void, Never>] = [:]
    private var pageTasks: [String: Task<Data, Error>] = [:]

    private var cacheRoot: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("StreamedPages", isDirectory: true)
    }

    private init() {
        try? fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    }

    func streamedPages(
        for book: Book,
        provider: any ServerPageProvider,
        mode: ComicPageLoadingMode
    ) async throws -> [URL] {
        let cacheKey = sanitize("\(book.providerId)-\(book.id)")
        let bookDir = cacheRoot.appendingPathComponent(cacheKey, isDirectory: true)
        try fileManager.createDirectory(at: bookDir, withIntermediateDirectories: true)

        let pageCount = try await provider.fetchPageCount(for: book)
        guard pageCount > 0 else {
            throw StreamingError.noPagesFound
        }

        let streamID: String
        if let existing = streamIDsByBook[cacheKey] {
            streamID = existing
        } else {
            streamID = UUID().uuidString.lowercased()
            streamIDsByBook[cacheKey] = streamID
        }
        fullCacheTasks.removeValue(forKey: streamID)?.cancel()
        sources[streamID] = StreamSource(
            book: book,
            provider: provider,
            cacheDirectory: bookDir,
            pageCount: pageCount,
            mode: mode
        )

        let pages = (0..<pageCount).compactMap { index in
            URL(string: "enve-comic-page://\(streamID)/\(index)")
        }
        if mode == .sessionCache {
            startFullCache(streamID: streamID)
        }
        return pages
    }

    func pageData(at url: URL) async throws -> Data {
        guard url.scheme == "enve-comic-page" else {
            return try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url)
            }.value
        }

        guard let streamID = url.host,
            let source = sources[streamID],
            let pageIndex = Int(url.lastPathComponent),
            pageIndex >= 0
        else {
            throw StreamingError.invalidPageURL
        }

        let cachedURL = cachedPageURL(index: pageIndex, in: source.cacheDirectory)
        if fileManager.fileExists(atPath: cachedURL.path) {
            return try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: cachedURL)
            }.value
        }

        let taskKey = cachedURL.path
        if let existing = pageTasks[taskKey] {
            return try await existing.value
        }

        let task = Task<Data, Error> {
            let data = try await source.provider.fetchPage(pageIndex + 1, for: source.book)
            try await Task.detached(priority: .utility) {
                try data.write(to: cachedURL, options: .atomic)
            }.value
            return data
        }
        pageTasks[taskKey] = task
        defer { pageTasks.removeValue(forKey: taskKey) }
        return try await task.value
    }

    func preparePageWindow(around url: URL) async {
        guard let (streamID, pageIndex) = streamLocation(for: url),
            let source = sources[streamID],
            source.mode == .onDemand
        else { return }

        let lowerBound = max(0, pageIndex - 3)
        let upperBound = min(source.pageCount - 1, pageIndex + 3)
        await withTaskGroup(of: Void.self) { group in
            for index in lowerBound...upperBound {
                group.addTask { [weak self] in
                    guard let self,
                        let pageURL = URL(string: "enve-comic-page://\(streamID)/\(index)")
                    else { return }
                    _ = try? await self.pageData(at: pageURL)
                }
            }
        }
        trimCache(in: source.cacheDirectory, keeping: lowerBound...upperBound)
    }

    func endSession(for book: Book) {
        let cacheKey = sanitize("\(book.providerId)-\(book.id)")
        guard let streamID = streamIDsByBook.removeValue(forKey: cacheKey),
            let source = sources.removeValue(forKey: streamID)
        else { return }
        fullCacheTasks.removeValue(forKey: streamID)?.cancel()
        cancelPageTasks(in: source.cacheDirectory)
        if source.mode == .sessionCache {
            try? fileManager.removeItem(at: source.cacheDirectory)
        }
    }

    func clearCache(for bookId: String) {
        let matchingSources = sources.filter { $0.value.book.id == bookId }
        for (streamID, source) in matchingSources {
            fullCacheTasks.removeValue(forKey: streamID)?.cancel()
            cancelPageTasks(in: source.cacheDirectory)
            try? fileManager.removeItem(at: source.cacheDirectory)
            sources.removeValue(forKey: streamID)
            streamIDsByBook.removeValue(forKey: source.cacheDirectory.lastPathComponent)
        }
        let legacyDirectory = cacheRoot.appendingPathComponent(sanitize(bookId), isDirectory: true)
        try? fileManager.removeItem(at: legacyDirectory)
    }

    private func startFullCache(streamID: String) {
        fullCacheTasks.removeValue(forKey: streamID)?.cancel()
        fullCacheTasks[streamID] = Task { [weak self] in
            await self?.cacheAllPages(streamID: streamID)
        }
    }

    private func cacheAllPages(streamID: String) async {
        guard let source = sources[streamID] else { return }
        for batchStart in stride(from: 0, to: source.pageCount, by: 4) {
            guard !Task.isCancelled else { return }
            let batchEnd = min(batchStart + 3, source.pageCount - 1)
            await withTaskGroup(of: Void.self) { group in
                for index in batchStart...batchEnd {
                    group.addTask { [weak self] in
                        guard let self,
                            let pageURL = URL(string: "enve-comic-page://\(streamID)/\(index)")
                        else { return }
                        _ = try? await self.pageData(at: pageURL)
                    }
                }
            }
        }
    }

    private func cancelPageTasks(in directory: URL) {
        let taskKeys = pageTasks.keys.filter { $0.hasPrefix(directory.path + "/") }
        for key in taskKeys {
            pageTasks.removeValue(forKey: key)?.cancel()
        }
    }

    private func trimCache(in directory: URL, keeping range: ClosedRange<Int>) {
        guard
            let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            )
        else { return }
        for file in files where file.pathExtension == "page" {
            guard let index = Int(file.deletingPathExtension().lastPathComponent),
                !range.contains(index)
            else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    private func streamLocation(for url: URL) -> (streamID: String, pageIndex: Int)? {
        guard url.scheme == "enve-comic-page",
            let streamID = url.host,
            let pageIndex = Int(url.lastPathComponent),
            pageIndex >= 0
        else { return nil }
        return (streamID, pageIndex)
    }

    private func cachedPageURL(index: Int, in directory: URL) -> URL {
        directory.appendingPathComponent(String(format: "%05d.page", index))
    }

    private func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression)
    }

    enum StreamingError: LocalizedError {
        case noPagesFound
        case invalidPageURL

        var errorDescription: String? {
            switch self {
            case .noPagesFound: return "Server returned no pages for this book"
            case .invalidPageURL: return "The streamed comic page URL is invalid"
            }
        }
    }

    private struct StreamSource {
        let book: Book
        let provider: any ServerPageProvider
        let cacheDirectory: URL
        let pageCount: Int
        var mode: ComicPageLoadingMode
    }
}
