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
