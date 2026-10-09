import UIKit
import CryptoKit
import Darwin
import Foundation

enum ProfileDownloadImportError: Error {
    case incompleteDownload
    case wrongDownload
    case sameProfile
    case missingMedia
    case invalidMediaPath
    case invalidReceipt
    case sourceChanged
    case missingEbookStorage
}

@MainActor
final class ProfileDownloadImportService {
    private struct Receipt: Codable {
        let sourceProfileID: String
        let sourceIdentity: String
        let book: Book
        let mediaNames: [String]
    }

    private let source: LocalStorageManager
    private let destination: LocalStorageManager
    private let sourceLocations: ProfileStorageLocations
    private let destinationLocations: ProfileStorageLocations
    private let sourceEbooks: LocalEbookImporter?
    private let destinationEbooks: LocalEbookImporter?
    private let fileManager = FileManager.default
    private let serialQueue = PerBookSerialQueue()
    private static let receiptName = "profile-import.json"

    init(
        source: LocalStorageManager, destination: LocalStorageManager,
        sourceEbooks: LocalEbookImporter? = nil, destinationEbooks: LocalEbookImporter? = nil
    ) {
        self.source = source
        self.destination = destination
        self.sourceEbooks = sourceEbooks
        self.destinationEbooks = destinationEbooks
        sourceLocations = source.profileStorageLocations
        destinationLocations = destination.profileStorageLocations
    }

    func importDownload(_ book: Book, completedTask: BookDownloadTask) async throws -> Book {
        let sourceImages = DiskImageCache(cacheDirectory: sourceLocations.cachesDirectory.appendingPathComponent("BookCovers"))
        let cachedCover = await sourceImages.image(for: book.coverURL)
        let coverData = cachedCover?.jpegData(compressionQuality: 0.9)
        var result: Result<Book, any Error>!
        await serialQueue.enqueue(bookId: book.uniqueId) {
            result = Result { try self.performImport(book, completedTask: completedTask, coverData: coverData) }
        }
        return try result.get()
    }

    func importLinkedDownloads(
        _ entries: [(book: Book, completedTask: BookDownloadTask)],
        publish: @escaping @MainActor ([Book]) async throws -> [Book] = { $0 }
    ) async throws -> [Book] {
        let sourceImages = DiskImageCache(cacheDirectory: sourceLocations.cachesDirectory.appendingPathComponent("BookCovers"))
        var covers: [Data?] = []
        for entry in entries {
            covers.append(await sourceImages.image(for: entry.book.coverURL)?.jpegData(compressionQuality: 0.9))
        }
        var result: Result<[Book], any Error>!
        await serialQueue.enqueue(bookId: entries[0].book.uniqueId) {
            var created: [URL] = []
            var receipts: [URL: Data] = [:]
            do {
                var staged: [Int: Book] = [:]
                let order = entries.indices.sorted {
                    entries[$0].book.mediaType == .ebook && entries[$1].book.mediaType != .ebook
                }
                for index in order {
                    let entry = entries[index]
                    let isEbook = entry.book.mediaType == .ebook
                    guard !isEbook || self.destinationEbooks != nil else { throw ProfileDownloadImportError.missingEbookStorage }
                    let root = isEbook ? self.destinationEbooks!.localEbooksRoot : self.destination.audiobooksDirectory
                    let previous = try self.existingImport(identity: self.sourceIdentity(for: entry.book), root: root, isEbook: isEbook)
                    var destinationReadAloudSourceStableId: String?
                    if let sourceID = entry.book.readAloudSourceStableId {
                        guard let sourceIndex = entries.firstIndex(where: { $0.book.stableId == sourceID }),
                            let sourceEbook = staged[sourceIndex], sourceEbook.mediaType == .ebook
                        else { throw ProfileDownloadImportError.missingMedia }
                        destinationReadAloudSourceStableId = sourceEbook.stableId
                    }
                    let book = try self.performImport(entry.book, completedTask: entry.completedTask, coverData: covers[index],
                        destinationReadAloudSourceStableId: destinationReadAloudSourceStableId)
                    let directory = isEbook ? root.appendingPathComponent(book.id, isDirectory: true) : self.destination.bookAudioDirectory(for: book.downloadKey)
                    if previous == nil { created.append(directory) }
                    let receiptURL = directory.appendingPathComponent(Self.receiptName)
                    receipts[receiptURL] = try Data(contentsOf: receiptURL)
                    staged[index] = book
                }
                var imported = entries.indices.map { staged[$0]! }
                for index in entries.indices {
                    let original = entries[index].book
                    if let target = entries.firstIndex(where: { $0.book.stableId == original.linkedAudiobookStableId }) {
                        imported[index].linkedAudiobookStableId = imported[target].stableId
                        imported[index].linkedAudiobookChapterOffset = original.linkedAudiobookChapterOffset
                    }
                    if let target = entries.firstIndex(where: { $0.book.stableId == original.readAloudSourceStableId }) {
                        imported[index].readAloudSourceStableId = imported[target].stableId
                    }
                    let isEbook = imported[index].mediaType == .ebook
                    let directory = isEbook
                        ? self.destinationEbooks!.localEbooksRoot.appendingPathComponent(imported[index].id, isDirectory: true)
                        : self.destination.bookAudioDirectory(for: imported[index].downloadKey)
                    let receiptURL = directory.appendingPathComponent(Self.receiptName)
                    let old = try JSONDecoder().decode(Receipt.self, from: receipts[receiptURL]!)
                    let receipt = Receipt(sourceProfileID: old.sourceProfileID, sourceIdentity: old.sourceIdentity,
                        book: imported[index], mediaNames: old.mediaNames)
                    try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
                }
                result = .success(try await publish(imported))
            } catch {
                for (url, data) in receipts where !created.contains(url.deletingLastPathComponent()) {
                    try? data.write(to: url, options: .atomic)
                }
                for directory in created { try? self.fileManager.removeItem(at: directory) }
                self.destination.invalidateDownloadedIdsCache()
                result = .failure(error)
            }
        }
        return try result.get()
    }

    private func performImport(_ book: Book, completedTask: BookDownloadTask, coverData: Data?,
        destinationReadAloudSourceStableId: String? = nil) throws -> Book {
        guard sourceLocations.profileID != destinationLocations.profileID else {
            throw ProfileDownloadImportError.sameProfile
        }
        guard completedTask.status == .completed, !source.hasActiveDownload(for: book) else {
            throw ProfileDownloadImportError.incompleteDownload
        }
        guard completedTask.bookId == book.downloadKey,
            completedTask.source == book.source
        else { throw ProfileDownloadImportError.wrongDownload }

        let isEbook = book.mediaType == .ebook
        let files: [URL]
        let finalRoot: URL
        let destinationBoundary: URL
        if isEbook {
            guard let sourceEbooks, let destinationEbooks,
                sourceEbooks.localEbooksRoot == sourceLocations.documentsDirectory.appendingPathComponent("Ebooks/local", isDirectory: true),
                destinationEbooks.localEbooksRoot == destinationLocations.documentsDirectory.appendingPathComponent("Ebooks/local", isDirectory: true)
            else { throw ProfileDownloadImportError.missingEbookStorage }
            finalRoot = destinationEbooks.localEbooksRoot
            destinationBoundary = destinationLocations.documentsDirectory
            try LocalStorageManager.validateImportPath(finalRoot, within: destinationBoundary)
            let identity = sourceIdentity(for: book)
            if let existing = try existingImport(identity: identity, root: finalRoot, isEbook: true) { return existing }
            guard let file = sourceEbooks.resolveExistingLocalEbookURL(
                bookIdentifier: book.id, ebookFileURL: book.ebookFileURL, filePath: book.filePath
            ) ?? sourceEbooks.resolveEbookForOverlay(book: book) else { throw ProfileDownloadImportError.missingMedia }
            let roots = [sourceEbooks.localEbooksRoot, sourceEbooks.serverEbooksRoot, sourceEbooks.remoteReaderCacheRoot, sourceEbooks.readaloudCacheRoot]
            guard let root = roots.first(where: { file.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }),
                EbookFormat.from(fileExtension: file.pathExtension.lowercased()) != nil
            else { throw ProfileDownloadImportError.invalidMediaPath }
            let sourceBoundary = root == sourceEbooks.remoteReaderCacheRoot
                ? sourceLocations.cachesDirectory : sourceLocations.documentsDirectory
            try LocalStorageManager.validateImportPath(file, within: sourceBoundary)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                throw ProfileDownloadImportError.missingMedia
            }
            files = [file]
        } else {
            finalRoot = destination.audiobooksDirectory
            destinationBoundary = destinationLocations.applicationSupportDirectory
            try LocalStorageManager.validateImportPath(finalRoot, within: destinationBoundary)
            let identity = sourceIdentity(for: book)
            if let existing = try existingImport(identity: identity, root: finalRoot, isEbook: false) { return existing }
            files = try source.completedAudiobookFiles(for: book)
        }
        let identity = sourceIdentity(for: book)

        let localID = UUID().uuidString
        let localProviderID = UUID()
        let backendID = "profile-imports"
        let localKey = destinationReadAloudSourceStableId.map { "storyalign:\($0)" } ?? "local:\(backendID):\(localID)"
        let finalDirectory = isEbook
            ? finalRoot.appendingPathComponent(localID, isDirectory: true)
            : destination.bookAudioDirectory(for: localKey)
        let stagingRoot = finalRoot.deletingLastPathComponent()
            .appendingPathComponent("ProfileImportStaging", isDirectory: true)
        try LocalStorageManager.validateImportPath(stagingRoot, within: destinationBoundary)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let staging = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        var tracks: [AudioTrack] = []
        var names: [String] = []
        for (index, file) in files.enumerated() {
            let name = isEbook ? "book.\(file.pathExtension.lowercased())" : "chapter_\(index).\(file.pathExtension.lowercased())"
            let before = try fileManager.attributesOfItem(atPath: file.path)
            guard clonefile(file.path, staging.appendingPathComponent(name).path, UInt32(CLONE_NOFOLLOW)) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let after = try fileManager.attributesOfItem(atPath: file.path)
            guard before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
                before[.size] as? NSNumber == after[.size] as? NSNumber,
                before[.modificationDate] as? Date == after[.modificationDate] as? Date
            else { throw ProfileDownloadImportError.sourceChanged }
            let original = book.audioTracks?.sorted { $0.index < $1.index }
            let track = original?.count == files.count ? original?[index] : nil
            tracks.append(AudioTrack(
                id: "\(localID)-\(index)", index: index,
                title: track?.title,
                filePath: finalDirectory.appendingPathComponent(name).path,
                duration: track?.duration ?? (files.count == 1 ? book.duration ?? 0 : 0),
                startOffset: track?.startOffset ?? 0,
                fileSize: (after[.size] as? NSNumber)?.int64Value,
                format: file.pathExtension.lowercased()
            ))
            names.append(name)
        }
        guard !source.hasActiveDownload(for: book) else { throw ProfileDownloadImportError.incompleteDownload }

        var coverURL: URL?
        let sourceCover = source.coverOverridePath(for: book.downloadKey)
        if fileManager.fileExists(atPath: sourceCover.path) {
            try LocalStorageManager.validateImportPath(sourceCover, within: sourceLocations.applicationSupportDirectory)
            try Data(contentsOf: sourceCover).write(to: staging.appendingPathComponent("cover.jpg"), options: .atomic)
            coverURL = finalDirectory.appendingPathComponent("cover.jpg")
        }
        if coverURL == nil, let sourceURL = book.coverURL, sourceURL.isFileURL {
            let boundary = [sourceLocations.applicationSupportDirectory, sourceLocations.documentsDirectory, sourceLocations.cachesDirectory]
                .first { sourceURL.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }
            if let boundary {
                try LocalStorageManager.validateImportPath(sourceURL, within: boundary)
                try Data(contentsOf: sourceURL).write(to: staging.appendingPathComponent("cover.jpg"), options: .atomic)
                coverURL = finalDirectory.appendingPathComponent("cover.jpg")
            }
        }
        if coverURL == nil, let coverData {
            try coverData.write(to: staging.appendingPathComponent("cover.jpg"), options: .atomic)
            coverURL = finalDirectory.appendingPathComponent("cover.jpg")
        }
        let chapters = book.chapters?.enumerated().map { index, chapter in
            Chapter(id: "\(localID)-chapter-\(index)", start: chapter.start, end: chapter.end, title: chapter.title, index: index)
        }
        let imported = Book(
            id: localID, title: book.title, author: book.author, narrator: book.narrator,
            duration: book.duration, coverURL: coverURL, audioTracks: isEbook ? nil : tracks,
            mediaType: book.mediaType, ebookFormat: isEbook ? files.first?.pathExtension.lowercased() : nil,
            ebookFileURL: isEbook ? finalDirectory.appendingPathComponent(names[0]) : nil,
            chapters: chapters, libraryId: backendID, providerId: localProviderID,
            backendId: backendID, source: .local, filePath: isEbook ? finalDirectory.appendingPathComponent(names[0]).path : tracks.first?.filePath,
            epub3Features: book.epub3Features, readAloudSourceStableId: destinationReadAloudSourceStableId
        )
        let metadata = OfflineBookMetadata(
            id: imported.id, stableId: imported.stableId, title: imported.title,
            author: imported.author, narrator: imported.narrator, duration: imported.duration,
            chapters: imported.chapters, audioTracks: imported.audioTracks,
            coverURLString: imported.thumb, source: .local
        )
        try JSONEncoder().encode(metadata).write(
            to: staging.appendingPathComponent("profile-import-metadata.json"), options: .atomic
        )
        let receipt = Receipt(
            sourceProfileID: sourceLocations.profileID, sourceIdentity: identity,
            book: imported, mediaNames: names
        )
        try JSONEncoder().encode(receipt).write(to: staging.appendingPathComponent(Self.receiptName), options: .atomic)
        try fileManager.moveItem(at: staging, to: finalDirectory)
        destination.invalidateDownloadedIdsCache()
        return imported
    }

    private func sourceIdentity(for book: Book) -> String {
        SHA256.hash(data: Data(book.uniqueId.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func existingImport(identity: String, root: URL, isEbook: Bool) throws -> Book? {
        let directories = try fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        for directory in directories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let receiptURL = directory.appendingPathComponent(Self.receiptName)
            guard fileManager.fileExists(atPath: receiptURL.path) else { continue }
            try LocalStorageManager.validateImportPath(receiptURL, within: root)
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptURL))
            guard receipt.sourceProfileID == sourceLocations.profileID, receipt.sourceIdentity == identity else { continue }
            let book = receipt.book
            let expected = isEbook ? root.appendingPathComponent(book.id, isDirectory: true) : destination.bookAudioDirectory(for: book.downloadKey)
            guard book.source == .local, book.backendId == "profile-imports", !receipt.mediaNames.isEmpty,
                directory.standardizedFileURL == expected.standardizedFileURL,
                (isEbook ? receipt.mediaNames.count == 1 : book.audioTracks?.count == receipt.mediaNames.count)
            else { throw ProfileDownloadImportError.invalidReceipt }
            for (index, name) in receipt.mediaNames.enumerated() {
                let expectedName = isEbook ? "book.\(URL(fileURLWithPath: name).pathExtension)" : "chapter_\(index).\(URL(fileURLWithPath: name).pathExtension)"
                guard name == expectedName,
                    (isEbook
                        ? book.ebookFileURL == directory.appendingPathComponent(name)
                        : book.audioTracks?[index].filePath == directory.appendingPathComponent(name).path)
                else { throw ProfileDownloadImportError.invalidReceipt }
                let file = directory.appendingPathComponent(name)
                try LocalStorageManager.validateImportPath(file, within: directory)
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
                    throw ProfileDownloadImportError.missingMedia
                }
            }
            return book
        }
        return nil
    }
}
