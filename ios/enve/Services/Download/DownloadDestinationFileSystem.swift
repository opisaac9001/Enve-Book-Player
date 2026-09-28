import Foundation

nonisolated struct DownloadDestinationFileSystem: Sendable {
    private let audiobooksRoot: URL

    init(audiobooksRoot: URL) {
        self.audiobooksRoot = audiobooksRoot
    }

    func bookDirectory(for bookId: String) -> URL {
        audiobooksRoot.appendingPathComponent(LocalStorageManager.sanitizedId(for: bookId), isDirectory: true)
    }

    @discardableResult
    func prepareBookDirectory(for bookId: String) throws -> URL {
        let directory = bookDirectory(for: bookId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // Refuses to replace a nonempty destination so a stalled migration stays retryable.
    @discardableResult
    func moveBookDirectory(from oldBookId: String, to newBookId: String) throws -> Bool {
        let fileManager = FileManager.default
        let source = bookDirectory(for: oldBookId)
        guard fileManager.fileExists(atPath: source.path) else { return false }
        let destination = bookDirectory(for: newBookId)
        if fileManager.fileExists(atPath: destination.path) {
            guard try fileManager.contentsOfDirectory(atPath: destination.path).isEmpty else {
                throw CocoaError(.fileWriteFileExists)
            }
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: source, to: destination)
        return true
    }

    @discardableResult
    func removeBookDirectory(for bookId: String) throws -> Bool {
        let directory = bookDirectory(for: bookId)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        try FileManager.default.removeItem(at: directory)
        return true
    }

    static func chapterFile(in directory: URL, index: Int, fileExtension: String) -> URL {
        directory.appendingPathComponent("chapter_\(index).\(fileExtension)")
    }

    static func replaceItem(at destination: URL, with sourceURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: sourceURL, to: destination)
    }
}
