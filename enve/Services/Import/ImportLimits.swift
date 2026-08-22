import Foundation

#if !os(tvOS)
import ReadiumZIPFoundation
#endif

nonisolated enum ImportLimitError: LocalizedError, Sendable {
    case directoryDepthExceeded(path: String, depth: Int, maxDepth: Int)
    case fileCountExceeded(path: String, count: Int, maxCount: Int)
    case fileTooLarge(path: String, size: Int64, maxSize: Int64)
    case archiveEntryCountExceeded(count: Int, maxCount: Int)
    case archiveUncompressedSizeExceeded(size: UInt64, maxSize: UInt64)
    case archivePathEscapesDestination(path: String)
    case archiveSymlinkUnsupported(path: String)
    case operationTimedOut(name: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .directoryDepthExceeded(let path, let depth, let maxDepth):
            return "Import path is too deep (\(depth)/\(maxDepth)): \(path)"
        case .fileCountExceeded(let path, let count, let maxCount):
            return "Import contains too many files (\(count)/\(maxCount)): \(path)"
        case .fileTooLarge(let path, let size, let maxSize):
            return "Import file is too large (\(size) bytes, max \(maxSize)): \(path)"
        case .archiveEntryCountExceeded(let count, let maxCount):
            return "Archive contains too many entries (\(count)/\(maxCount))"
        case .archiveUncompressedSizeExceeded(let size, let maxSize):
            return "Archive expands beyond the allowed budget (\(size) bytes, max \(maxSize))"
        case .archivePathEscapesDestination(let path):
            return "Archive entry escapes the extraction folder: \(path)"
        case .archiveSymlinkUnsupported(let path):
            return "Archive symlinks are not supported: \(path)"
        case .operationTimedOut(let name, let seconds):
            return "\(name) timed out after \(Int(seconds))s"
        }
    }
}

nonisolated enum ImportLimits {
    static let maxDirectoryDepth = 32
    static let maxFilesPerScan = 250_000
    static let maxArchiveBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let maxArchiveEntryCount = 50_000
    static let maxArchiveUncompressedBytes: UInt64 = 32 * 1024 * 1024 * 1024
    static let maxWholeFileReadBytes: Int64 = 512 * 1024 * 1024
    static let maxImportedMediaFileBytes: Int64 = 8 * 1024 * 1024 * 1024
    static let metadataExtractionTimeoutSeconds: TimeInterval = 20
    static let scanYieldInterval = 256

    static func validateArchiveFile(_ url: URL) throws {
        try validateFileSize(url, maxBytes: maxArchiveBytes)
    }

    static func validateImportedMediaFile(_ url: URL) throws {
        try validateFileSize(url, maxBytes: maxImportedMediaFileBytes)
    }

    static func validateWholeFileRead(_ url: URL) throws {
        try validateFileSize(url, maxBytes: maxWholeFileReadBytes)
    }

    static func validateFileSize(_ url: URL, maxBytes: Int64) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values.isDirectory != true else { return }
        let size = Int64(values.fileSize ?? 0)
        guard size <= maxBytes else {
            throw ImportLimitError.fileTooLarge(path: url.path, size: size, maxSize: maxBytes)
        }
    }

    static func validateArchiveEntryPath(_ path: String, destinationRoot: URL) throws -> URL {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty,
            !normalized.hasPrefix("/"),
            !normalized.hasPrefix("~"),
            !normalized.contains("\0")
        else {
            throw ImportLimitError.archivePathEscapesDestination(path: path)
        }

        let components =
            normalized
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard !components.isEmpty,
            !components.contains("."),
            !components.contains("..")
        else {
            throw ImportLimitError.archivePathEscapesDestination(path: path)
        }

        let candidate = components.reduce(destinationRoot) { url, component in
            url.appendingPathComponent(component)
        }

        let rootPath = destinationRoot.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw ImportLimitError.archivePathEscapesDestination(path: path)
        }
        return candidate
    }

    #if !os(tvOS)
    static func extractArchive(
        _ archiveURL: URL,
        to destinationRoot: URL,
        fileManager: FileManager = .default
    ) async throws {
        try validateArchiveFile(archiveURL)

        let archive = try await Archive(url: archiveURL, accessMode: .read)
        let entries = try await archive.entries()
        var entryCount = 0
        var uncompressedBytes: UInt64 = 0
        var extractionPlan: [(entry: Entry, destination: URL)] = []

        for entry in entries {
            try Task.checkCancellation()
            entryCount += 1
            guard entryCount <= maxArchiveEntryCount else {
                throw ImportLimitError.archiveEntryCountExceeded(
                    count: entryCount,
                    maxCount: maxArchiveEntryCount
                )
            }

            guard entry.type != .symlink else {
                throw ImportLimitError.archiveSymlinkUnsupported(path: entry.path)
            }

            if entry.type == .file {
                uncompressedBytes += entry.uncompressedSize
                guard uncompressedBytes <= maxArchiveUncompressedBytes else {
                    throw ImportLimitError.archiveUncompressedSizeExceeded(
                        size: uncompressedBytes,
                        maxSize: maxArchiveUncompressedBytes
                    )
                }
            }

            let destinationURL = try validateArchiveEntryPath(
                entry.path,
                destinationRoot: destinationRoot
            )
            extractionPlan.append((entry, destinationURL))
        }

        for item in extractionPlan {
            try Task.checkCancellation()
            if item.entry.type == .directory, fileManager.fileExists(atPath: item.destination.path) {
                continue
            }
            if item.entry.type == .file, fileManager.fileExists(atPath: item.destination.path) {
                try fileManager.removeItem(at: item.destination)
            }
            _ = try await archive.extract(item.entry, to: item.destination)
        }
    }

    #endif

    static func relativePath(for url: URL, under root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
        var relative = String(path.dropFirst(rootPath.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative
    }

    static func depth(of relativePath: String) -> Int {
        relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .count
    }

    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operationName: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw ImportLimitError.operationTimedOut(name: operationName, seconds: seconds)
            }

            guard let result = try await group.next() else {
                throw ImportLimitError.operationTimedOut(name: operationName, seconds: seconds)
            }
            group.cancelAll()
            return result
        }
    }
}

nonisolated struct ImportScanBudget: Sendable {
    private(set) var count = 0

    let maxFiles: Int
    let maxDepth: Int
    let yieldInterval: Int

    init(
        maxFiles: Int = ImportLimits.maxFilesPerScan,
        maxDepth: Int = ImportLimits.maxDirectoryDepth,
        yieldInterval: Int = ImportLimits.scanYieldInterval
    ) {
        self.maxFiles = maxFiles
        self.maxDepth = maxDepth
        self.yieldInterval = yieldInterval
    }

    mutating func record(path: String, relativePath: String) throws {
        try Task.checkCancellation()
        count += 1
        guard count <= maxFiles else {
            throw ImportLimitError.fileCountExceeded(path: path, count: count, maxCount: maxFiles)
        }

        let depth = ImportLimits.depth(of: relativePath)
        guard depth <= maxDepth else {
            throw ImportLimitError.directoryDepthExceeded(path: path, depth: depth, maxDepth: maxDepth)
        }
    }

    mutating func record(url: URL, root: URL) throws {
        try record(
            path: url.path,
            relativePath: ImportLimits.relativePath(for: url, under: root)
        )
    }

    mutating func recordAsync(url: URL, root: URL) async throws {
        try record(url: url, root: root)
        if count.isMultiple(of: yieldInterval) {
            await Task.yield()
        }
    }
}
