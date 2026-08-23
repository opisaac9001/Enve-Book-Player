import AVFoundation
import CryptoKit
import Foundation
import Logging
import MediaPlayer

public actor LocalLibraryService {
    public static let shared = LocalLibraryService()
    nonisolated static let fileSharingLibraryId = "file-sharing"
    nonisolated static var fileSharingRootURL: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsURL
    }
    private var fileSharingAudiobooksFolder: URL {
        LocalLibraryService.fileSharingRootURL.appendingPathComponent("Individual_Audiobooks", isDirectory: true)
    }

    let fileManager = FileManager.default
    let metadataExtractor = FileMetadataExtractor()
    let audioMetadataEmbedder = AudioMetadataEmbedder()

    public init() {}

    func loadMetadataForDownloadedAudio(at filePath: String) async throws -> LocalBookMetadata {
        let fileName = URL(fileURLWithPath: filePath).lastPathComponent

        let sidecarCandidates = sidecarCandidatePaths(forAudioFilePath: filePath)
        var sidecarMetadata: LocalBookMetadata?

        for candidate in sidecarCandidates {
            guard fileManager.fileExists(atPath: candidate) else { continue }
            do {
                sidecarMetadata = try await loadSidecarMetadata(from: candidate)
                break
            } catch {
                AppLogger.network.error(
                    "Could not load downloaded sidecar pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: URL(fileURLWithPath: candidate).standardizedFileURL.path)): \(error)"
                )
            }
        }

        let embeddedMetadata: LocalBookMetadata
        do {
            embeddedMetadata = try await extractAudioMetadata(from: filePath)
        } catch {
            embeddedMetadata = try createBasicMetadata(from: fileName)
        }

        var merged: LocalBookMetadata
        if let sidecarMetadata {
            merged = LocalBookMetadata(
                title: sidecarMetadata.title.isEmpty ? embeddedMetadata.title : sidecarMetadata.title,
                author: sidecarMetadata.author ?? embeddedMetadata.author,
                narrator: sidecarMetadata.narrator ?? embeddedMetadata.narrator,
                description: sidecarMetadata.description ?? embeddedMetadata.description,
                series: sidecarMetadata.series ?? embeddedMetadata.series,
                seriesNumber: sidecarMetadata.seriesNumber ?? embeddedMetadata.seriesNumber,
                seriesSequence: sidecarMetadata.seriesSequence ?? embeddedMetadata.seriesSequence,
                publishedYear: sidecarMetadata.publishedYear ?? embeddedMetadata.publishedYear,
                genres: (sidecarMetadata.genres?.isEmpty == false) ? sidecarMetadata.genres : embeddedMetadata.genres,
                publisher: sidecarMetadata.publisher ?? embeddedMetadata.publisher,
                isbn: sidecarMetadata.isbn ?? embeddedMetadata.isbn,
                asin: sidecarMetadata.asin ?? embeddedMetadata.asin,
                duration: sidecarMetadata.duration ?? embeddedMetadata.duration,
                chapters: (sidecarMetadata.chapters?.isEmpty == false) ? sidecarMetadata.chapters : embeddedMetadata.chapters,
                coverImagePath: sidecarMetadata.coverImagePath ?? embeddedMetadata.coverImagePath,
                lastUpdated: Date(),
                metadataVersion: sidecarMetadata.metadataVersion,
                copyright: sidecarMetadata.copyright ?? embeddedMetadata.copyright,
                language: sidecarMetadata.language ?? embeddedMetadata.language,
                encodingTool: sidecarMetadata.encodingTool ?? embeddedMetadata.encodingTool
            )
        } else {
            merged = embeddedMetadata
        }

        if merged.coverImagePath?.isEmpty != false {
            merged.coverImagePath = companionCoverPath(forAudioFilePath: filePath)
        }

        return merged
    }

    func deleteBookFiles(for book: Book) throws {
        guard book.source == .local else { return }

        var targets: [URL] = []

        let trackURLs = (book.audioTracks ?? [])
            .compactMap { $0.filePath }
            .map { URL(fileURLWithPath: $0) }

        if trackURLs.count > 1,
            let parent = commonParentDirectory(for: trackURLs),
            fileManager.fileExists(atPath: parent.path)
        {
            targets = [parent]
        } else if let path = book.filePath {
            targets = [URL(fileURLWithPath: path)]
        }

        guard !targets.isEmpty else {
            throw NSError(
                domain: "LocalLibraryService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No local file path found for book"]
            )
        }

        var errors: [Error] = []
        for target in targets {
            var companionFiles: [URL] = []
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                companionFiles.append(target.deletingPathExtension().appendingPathExtension("json"))
                companionFiles.append(URL(fileURLWithPath: LocalBookFile.sidecarPath(for: target.path)))

                let baseURL = target.deletingPathExtension()
                for ext in ["jpg", "jpeg", "png", "webp"] {
                    companionFiles.append(baseURL.appendingPathExtension("cover.\(ext)"))
                }
            }

            if fileManager.fileExists(atPath: target.path) {
                do {
                    try fileManager.removeItem(at: target)
                    AppLogger.network.info("Deleted local target \(DiagnosticLogSanitizer.fileDescriptor(for: target))")
                } catch {
                    errors.append(error)
                    AppLogger.network.error(
                        "Failed to delete local target pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: target.standardizedFileURL.path)): \(error.localizedDescription)"
                    )
                }
            }

            for companion in Set(companionFiles) where fileManager.fileExists(atPath: companion.path) {
                try? fileManager.removeItem(at: companion)
                AppLogger.network.info("Deleted companion file \(DiagnosticLogSanitizer.fileDescriptor(for: companion))")
            }
        }

        if let first = errors.first {
            throw first
        }
    }

    func deleteLocalBookFile(_ bookFile: LocalBookFile) throws {
        var targets: [URL] = []

        let audioFileURLs = (bookFile.audioFiles ?? [])
            .map { URL(fileURLWithPath: $0.filePath) }

        if audioFileURLs.count > 1,
            let parent = commonParentDirectory(for: audioFileURLs),
            fileManager.fileExists(atPath: parent.path)
        {
            targets = [parent]
        } else if !audioFileURLs.isEmpty {
            targets = audioFileURLs
        } else {
            targets = [URL(fileURLWithPath: bookFile.filePath)]
        }

        var errors: [Error] = []
        for target in targets {
            let sidecar: URL?
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                sidecar = target.deletingPathExtension().appendingPathExtension("json")
            } else {
                sidecar = nil
            }

            if fileManager.fileExists(atPath: target.path) {
                do {
                    try fileManager.removeItem(at: target)
                    AppLogger.network.info("Deleted local target \(DiagnosticLogSanitizer.fileDescriptor(for: target))")
                } catch {
                    errors.append(error)
                    AppLogger.network.error(
                        "Failed to delete local target pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: target.standardizedFileURL.path)): \(error.localizedDescription)"
                    )
                }
            }

            if let sidecar, fileManager.fileExists(atPath: sidecar.path) {
                try? fileManager.removeItem(at: sidecar)
                AppLogger.network.info("Deleted sidecar \(DiagnosticLogSanitizer.fileDescriptor(for: sidecar))")
            }
        }

        if let sidecarPath = bookFile.sidecarPath, fileManager.fileExists(atPath: sidecarPath) {
            try? fileManager.removeItem(atPath: sidecarPath)
            AppLogger.network.info(
                "Deleted sidecar \(DiagnosticLogSanitizer.fileDescriptor(for: URL(fileURLWithPath: sidecarPath)))"
            )
        }

        if let first = errors.first {
            throw first
        }
    }

    func removeBookFromScanCache(bookId: String, libraryId: String, filePath: String? = nil) async {
        await MainActor.run {
            var books = LocalLibraryStorageStore.shared.loadBooks(libraryId: libraryId)
            let beforeCount = books.count
            books.removeAll { localBook in
                if localBook.id == bookId {
                    return true
                }
                if let filePath, !filePath.isEmpty, localBook.filePath == filePath {
                    return true
                }
                return false
            }
            if books.count < beforeCount {
                let result = LocalLibraryScanResult(
                    localLibraryId: libraryId,
                    booksFound: books,
                    skippedFiles: [],
                    scanDuration: 0,
                    scannedAt: Date()
                )
                LocalLibraryStorageStore.shared.saveScanResult(result)
                AppLogger.network.info(
                    "Removed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookId)) from libraryDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: libraryId)); count=\(beforeCount)->\(books.count)"
                )
            }
        }
    }

    nonisolated func createLibrary(name: String, folderPath: String) -> LocalLibrary {
        return LocalLibrary(
            name: name,
            folderPath: folderPath,
            createdAt: Date(),
            isEnabled: true
        )
    }

    func scanLibrary(_ library: LocalLibrary) async throws -> LocalLibraryScanResult {
        let startTime = Date()

        AppLogger.network.info(
            "Scanning local library libraryDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: library.id)) pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: URL(fileURLWithPath: library.folderPath).standardizedFileURL.path))"
        )

        if library.type == .fileSharing {
            return try await scanCanonicalLibrary(libraryId: library.id)
        }

        var bookmarkURL: URL?

        if let bookmarkData = LocalLibraryStorageStore.shared.loadBookmark(for: library.id) {
            AppLogger.network.info("Found security bookmark for library")
            var isStale = false
            do {
                #if os(macOS)
                bookmarkURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                #else
                bookmarkURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withoutUI,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                #endif

                if isStale {
                    AppLogger.network.info("Bookmark is stale, attempting to re-create...")
                    if let resolvedURL = bookmarkURL {
                        do {
                            #if os(macOS)
                            let newBookmarkData = try resolvedURL.bookmarkData(
                                options: .withSecurityScope,
                                includingResourceValuesForKeys: nil,
                                relativeTo: nil
                            )
                            #else
                            let newBookmarkData = try resolvedURL.bookmarkData(
                                options: .minimalBookmark,
                                includingResourceValuesForKeys: nil,
                                relativeTo: nil
                            )
                            #endif
                            let libId = library.id
                            Task { @MainActor in
                                LocalLibraryStorageStore.shared.saveBookmark(newBookmarkData, for: libId)
                            }
                            AppLogger.network.info("Bookmark re-created successfully")
                        } catch {
                            AppLogger.network.error("Failed to re-create bookmark: \(error)")
                        }
                    }
                }
            } catch {
                AppLogger.network.error("Failed to resolve bookmark: \(error)")
            }
        } else {
            AppLogger.network.info(
                "No security bookmark found for libraryDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: library.id))"
            )
        }

        if let url = bookmarkURL {
            let isAccessingResource = url.startAccessingSecurityScopedResource()
            AppLogger.network.info("Started accessing security-scoped resource: \(isAccessingResource)")
            defer {
                url.stopAccessingSecurityScopedResource()
                AppLogger.network.info("Stopped accessing security-scoped resource")
            }

            return try await performScanWithURL(url: url, library: library, startTime: startTime)
        } else {
            AppLogger.network.info("Using original path (no security-scoped access)")
            return try await performScan(path: library.folderPath, library: library, startTime: startTime)
        }
    }

    private func performScanWithURL(url: URL, library: LocalLibrary, startTime: Date) async throws -> LocalLibraryScanResult {
        AppLogger.network.info(
            "Scanning URL recursively pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: url.standardizedFileURL.path))"
        )
        AppLogger.network.info("URL scheme: \(url.scheme ?? "none"), isFileURL: \(url.isFileURL)")

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            AppLogger.network.warning(
                "Folder not found or not a directory pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: url.standardizedFileURL.path))"
            )
            throw LocalLibraryError.folderNotFound
        }

        AppLogger.network.info("Folder exists and is a directory")

        var booksFound: [LocalBookFile] = []
        var skippedFiles: [String] = []

        final class FilesAccumulator: @unchecked Sendable {
            var files: [(name: String, url: URL, relativePath: String)] = []
        }
        let filesAccumulator = FilesAccumulator()

        AppLogger.network.info("Strategy 0: NSFileCoordinator enumeration")
        var coordinatedBudget = ImportScanBudget()
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [.immediatelyAvailableMetadataOnly], error: &coordinatorError) { accessedURL in
            AppLogger.network.info(
                "Coordinated access pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: accessedURL.standardizedFileURL.path))"
            )
            do {
                let contents = try fileManager.contentsOfDirectory(
                    at: accessedURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                AppLogger.network.info("Coordinator found \(contents.count) items at root")

                func scanCoordinated(at directoryURL: URL, relativePath: String) {
                    do {
                        let items = try fileManager.contentsOfDirectory(
                            at: directoryURL,
                            includingPropertiesForKeys: [.isDirectoryKey],
                            options: [.skipsHiddenFiles]
                        )
                        for itemURL in items {
                            let fileName = itemURL.lastPathComponent
                            let itemRelativePath = relativePath.isEmpty ? fileName : "\(relativePath)/\(fileName)"
                            do {
                                try coordinatedBudget.record(path: itemURL.path, relativePath: itemRelativePath)
                            } catch {
                                AppLogger.network.error(
                                    "Stopping coordinated enumeration pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: itemURL.standardizedFileURL.path)): \(error.localizedDescription)"
                                )
                                return
                            }

                            var isDir: ObjCBool = false
                            if fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDir), isDir.boolValue {
                                AppLogger.network.debug(
                                    "Entering directory pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: itemURL.standardizedFileURL.path))"
                                )
                                scanCoordinated(at: itemURL, relativePath: itemRelativePath)
                                continue
                            }

                            let ext = itemURL.pathExtension.lowercased()
                            if let format = AudiobookFormat.from(fileExtension: ext) {
                                AppLogger.network.debug(
                                    "Found audio \(DiagnosticLogSanitizer.fileDescriptor(for: itemURL)) format=\(format.rawValue)"
                                )
                                filesAccumulator.files.append((name: fileName, url: itemURL, relativePath: itemRelativePath))
                            }
                        }
                    } catch {
                        AppLogger.network.error(
                            "Failed to enumerate pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: directoryURL.standardizedFileURL.path)): \(error.localizedDescription)"
                        )
                    }
                }

                scanCoordinated(at: accessedURL, relativePath: "")
            } catch {
                AppLogger.network.error("Root enumeration failed: \(error.localizedDescription)")
            }
        }

        var filesToProcess = filesAccumulator.files

        if let error = coordinatorError {
            AppLogger.network.error("NSFileCoordinator error: \(error.localizedDescription)")
        }

        if filesToProcess.isEmpty {
            AppLogger.network.info("Strategy 1: URL-based enumeration")
            var urlBudget = ImportScanBudget()
            func scanDirectoryURL(at directoryURL: URL, relativePath: String) {
                AppLogger.network.debug(
                    "Scanning directory pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: directoryURL.standardizedFileURL.path))"
                )
                do {
                    let contents = try fileManager.contentsOfDirectory(
                        at: directoryURL,
                        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
                        options: [.skipsHiddenFiles]
                    )
                    AppLogger.network.debug("Found \(contents.count) items during directory scan")

                    for itemURL in contents {
                        let fileName = itemURL.lastPathComponent
                        let itemRelativePath = relativePath.isEmpty ? fileName : "\(relativePath)/\(fileName)"
                        do {
                            try urlBudget.record(path: itemURL.path, relativePath: itemRelativePath)
                        } catch {
                            AppLogger.network.error(
                                "Stopping URL enumeration pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: itemURL.standardizedFileURL.path)): \(error.localizedDescription)"
                            )
                            return
                        }

                        var isDir: ObjCBool = false
                        if fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDir) {
                            if isDir.boolValue {
                                AppLogger.network.debug(
                                    "Entering directory pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: itemURL.standardizedFileURL.path))"
                                )
                                scanDirectoryURL(at: itemURL, relativePath: itemRelativePath)
                                continue
                            }
                        }

                        let fileExtension = itemURL.pathExtension.lowercased()

                        if let format = AudiobookFormat.from(fileExtension: fileExtension) {
                            AppLogger.network.debug(
                                "Found audio \(DiagnosticLogSanitizer.fileDescriptor(for: itemURL)) format=\(format.rawValue)"
                            )
                            filesToProcess.append((name: fileName, url: itemURL, relativePath: itemRelativePath))
                        }
                    }
                } catch {
                    AppLogger.network.error(
                        "URL enumeration failed pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: directoryURL.standardizedFileURL.path)): \(error.localizedDescription)"
                    )
                }
            }

            scanDirectoryURL(at: url, relativePath: "")
        }

        if filesToProcess.isEmpty {
            AppLogger.network.info("Strategy 2: Path-based DirectoryEnumerator")
            if let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles],
                errorHandler: { (url, error) -> Bool in
                    AppLogger.network.error(
                        "Enumerator error pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: url.standardizedFileURL.path)): \(error.localizedDescription)"
                    )
                    return true
                }
            ) {
                var enumBudget = ImportScanBudget()
                while let fileURL = enumerator.nextObject() as? URL {
                    try await enumBudget.recordAsync(url: fileURL, root: url)
                    let fileName = fileURL.lastPathComponent

                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                        continue
                    }

                    let fileExtension = fileURL.pathExtension.lowercased()

                    if let format = AudiobookFormat.from(fileExtension: fileExtension) {
                        let relativePath = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
                        AppLogger.network.debug(
                            "Found enumerated audio \(DiagnosticLogSanitizer.fileDescriptor(for: fileURL)) format=\(format.rawValue)"
                        )
                        filesToProcess.append((name: fileName, url: fileURL, relativePath: relativePath))
                    }
                }
            }
        }

        if filesToProcess.isEmpty {
            AppLogger.network.info("Strategy 3 skipped: unbounded subpath materialization is disabled")
        }

        AppLogger.network.info("Total audio files found: \(filesToProcess.count)")

        let forcedStandalonePaths = await MainActor.run {
            AudiobookGroupingOverrideStore.shared.forcedStandalonePaths(source: .local, sourceId: library.id)
        }
        let audiobooks = groupFilesIntoBooks(
            files: filesToProcess,
            forcedStandalonePaths: forcedStandalonePaths
        )
        AppLogger.network.info("Grouped into \(audiobooks.count) audiobook(s)")

        for audiobook in audiobooks {
            try Task.checkCancellation()
            do {
                if audiobook.isSingleFile {
                    let fileInfo = filesToProcess.first { $0.url == audiobook.files[0].url }!
                    let bookFile = try await extractBookFileFromURL(
                        url: fileInfo.url,
                        fileName: fileInfo.name,
                        libraryId: library.id,
                        relativePath: fileInfo.relativePath,
                        includeFolderMetadata: audiobook.allowsFolderMetadata
                    )
                    booksFound.append(bookFile)
                    AppLogger.network.info(
                        "Found single-file bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))"
                    )
                } else {
                    let bookFile = try await extractMultiFileAudiobook(
                        audiobook: audiobook,
                        libraryId: library.id
                    )
                    booksFound.append(bookFile)
                    AppLogger.network.info(
                        "Found multi-file bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id)) files=\(audiobook.fileCount)"
                    )
                }
            } catch {
                AppLogger.network.error(
                    "Could not process audiobook pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: URL(fileURLWithPath: audiobook.folderPath).standardizedFileURL.path)): \(error)"
                )
                skippedFiles.append(audiobook.folderName)
            }
        }

        let scanDuration = Date().timeIntervalSince(startTime)

        AppLogger.network.warning("Scan complete: Found \(booksFound.count) books, skipped \(skippedFiles.count) files")
        AppLogger.network.info("Scan duration: \(String(format: "%.2f", scanDuration))s")

        return LocalLibraryScanResult(
            localLibraryId: library.id,
            booksFound: booksFound,
            skippedFiles: skippedFiles,
            scanDuration: scanDuration,
            scannedAt: Date()
        )
    }

    private func commonParentDirectory(for urls: [URL]) -> URL? {
        guard let first = urls.first else { return nil }
        let firstParent = first.deletingLastPathComponent()
        let allSameParent = urls.allSatisfy { $0.deletingLastPathComponent().path == firstParent.path }
        return allSameParent ? firstParent : nil
    }

    private func performScan(path: String, library: LocalLibrary, startTime: Date) async throws -> LocalLibraryScanResult {
        AppLogger.network.info(
            "Scanning pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: URL(fileURLWithPath: path).standardizedFileURL.path))"
        )

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            AppLogger.network.warning(
                "Folder not found or not a directory pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: URL(fileURLWithPath: path).standardizedFileURL.path))"
            )
            throw LocalLibraryError.folderNotFound
        }

        AppLogger.network.info("Folder exists and is a directory")

        var booksFound: [LocalBookFile] = []
        var skippedFiles: [String] = []

        var filesToProcess: [(name: String, url: URL, relativePath: String)] = []

        if let enumerator = fileManager.enumerator(atPath: path) {
            var scanBudget = ImportScanBudget()
            var itemCount = 0

            while let fileName = enumerator.nextObject() as? String {
                itemCount += 1
                if fileName.hasPrefix(".") || fileName.contains("/.") {
                    AppLogger.network.debug("Skipping hidden file")
                    continue
                }

                let filePath = (path as NSString).appendingPathComponent(fileName)
                try await scanBudget.recordAsync(url: URL(fileURLWithPath: filePath), root: URL(fileURLWithPath: path))

                var isDir: ObjCBool = false
                guard fileManager.fileExists(atPath: filePath, isDirectory: &isDir),
                    !isDir.boolValue
                else {
                    AppLogger.network.debug(
                        "Skipping directory pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: URL(fileURLWithPath: filePath).standardizedFileURL.path))"
                    )
                    continue
                }

                let fileExtension = (fileName as NSString).pathExtension.lowercased()
                AppLogger.network.debug("Checking media file extension=.\(fileExtension)")

                if let format = AudiobookFormat.from(fileExtension: fileExtension) {
                    AppLogger.network.info("Supported format: \(format.rawValue)")
                    let fileURL = URL(fileURLWithPath: filePath)
                    filesToProcess.append((name: fileURL.lastPathComponent, url: fileURL, relativePath: fileName))
                } else {
                    AppLogger.network.info("Unsupported format: .\(fileExtension)")
                    skippedFiles.append(fileName)
                }
            }

            AppLogger.network.info("Found \(itemCount) total items in directory")

            if itemCount == 0 {
                AppLogger.network.info("Directory enumerator returned 0 items. Trying direct contents enumeration...")
                do {
                    let contents = try fileManager.contentsOfDirectory(atPath: path)
                    AppLogger.network.info("Direct enumeration found \(contents.count) items")

                    for fileName in contents {
                        try Task.checkCancellation()
                        guard !fileName.hasPrefix(".") && !fileName.contains("/.") else {
                            AppLogger.network.debug("Skipping hidden file")
                            continue
                        }

                        let filePath = (path as NSString).appendingPathComponent(fileName)
                        try await scanBudget.recordAsync(url: URL(fileURLWithPath: filePath), root: URL(fileURLWithPath: path))

                        var isDir: ObjCBool = false
                        guard fileManager.fileExists(atPath: filePath, isDirectory: &isDir),
                            !isDir.boolValue
                        else {
                            AppLogger.network.debug(
                                "Skipping directory pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: URL(fileURLWithPath: filePath).standardizedFileURL.path))"
                            )
                            continue
                        }

                        let fileExtension = (fileName as NSString).pathExtension.lowercased()
                        AppLogger.network.debug("Checking media file extension=.\(fileExtension)")

                        if let format = AudiobookFormat.from(fileExtension: fileExtension) {
                            AppLogger.network.info("Supported format: \(format.rawValue)")
                            let fileURL = URL(fileURLWithPath: filePath)
                            filesToProcess.append((name: fileURL.lastPathComponent, url: fileURL, relativePath: fileName))
                        } else {
                            AppLogger.network.info("Unsupported format: .\(fileExtension)")
                            skippedFiles.append(fileName)
                        }
                    }
                } catch {
                    AppLogger.network.error("Direct enumeration also failed: \(error)")
                }
            }
        } else {
            AppLogger.network.info(
                "Could not create enumerator pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: URL(fileURLWithPath: library.folderPath).standardizedFileURL.path))"
            )
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: path)
                AppLogger.network.warning("Fallback enumeration found \(contents.count) items")
                var fallbackBudget = ImportScanBudget()

                for fileName in contents {
                    try Task.checkCancellation()
                    guard !fileName.hasPrefix(".") else { continue }

                    let filePath = (path as NSString).appendingPathComponent(fileName)
                    try await fallbackBudget.recordAsync(url: URL(fileURLWithPath: filePath), root: URL(fileURLWithPath: path))
                    let fileExtension = (fileName as NSString).pathExtension.lowercased()
                    var isDir: ObjCBool = false

                    if fileManager.fileExists(atPath: filePath, isDirectory: &isDir), !isDir.boolValue {
                        if let _ = AudiobookFormat.from(fileExtension: fileExtension) {
                            let fileURL = URL(fileURLWithPath: filePath)
                            filesToProcess.append((name: fileURL.lastPathComponent, url: fileURL, relativePath: fileName))
                        }
                    }
                }
            } catch {
                AppLogger.network.error("Fallback enumeration failed: \(error)")
            }
        }

        let forcedStandalonePaths = await MainActor.run {
            AudiobookGroupingOverrideStore.shared.forcedStandalonePaths(source: .local, sourceId: library.id)
        }
        let audiobooks = groupFilesIntoBooks(
            files: filesToProcess,
            forcedStandalonePaths: forcedStandalonePaths
        )
        AppLogger.network.info("Grouped \(filesToProcess.count) audio files into \(audiobooks.count) audiobook(s)")

        for audiobook in audiobooks {
            try Task.checkCancellation()
            do {
                let bookFile: LocalBookFile
                if audiobook.isSingleFile {
                    let file = audiobook.files[0]
                    bookFile = try await extractBookFileFromURL(
                        url: file.url,
                        fileName: file.name,
                        libraryId: library.id,
                        relativePath: file.relativePath,
                        includeFolderMetadata: audiobook.allowsFolderMetadata
                    )
                } else {
                    bookFile = try await extractMultiFileAudiobook(
                        audiobook: audiobook,
                        libraryId: library.id
                    )
                }
                booksFound.append(bookFile)
                AppLogger.network.info(
                    "Found bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))"
                )
            } catch {
                AppLogger.network.error(
                    "Could not process audiobook pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: URL(fileURLWithPath: audiobook.folderPath).standardizedFileURL.path)): \(error)"
                )
                skippedFiles.append(audiobook.folderName)
            }
        }

        let scanDuration = Date().timeIntervalSince(startTime)

        AppLogger.network.warning("Scan complete: Found \(booksFound.count) books, skipped \(skippedFiles.count) files")
        AppLogger.network.info("Scan duration: \(String(format: "%.2f", scanDuration))s")

        return LocalLibraryScanResult(
            localLibraryId: library.id,
            booksFound: booksFound,
            skippedFiles: skippedFiles,
            scanDuration: scanDuration,
            scannedAt: Date()
        )
    }

    private func extractBookFileFromURL(
        url: URL,
        fileName: String,
        libraryId: String,
        relativePath: String?,
        includeFolderMetadata: Bool
    ) async throws -> LocalBookFile {
        try Task.checkCancellation()
        try ImportLimits.validateImportedMediaFile(url)
        let filePath = url.path

        let fileAttributes = try fileManager.attributesOfItem(atPath: filePath)
        let fileSize = fileAttributes[.size] as? NSNumber ?? NSNumber(value: 0)
        let fileExtension = url.pathExtension.lowercased()

        let fileHash = try calculateFileHash(filePath: filePath)
        let stableId = "\(libraryId):\(fileHash)"

        let sidecarCandidates = sidecarCandidatePaths(
            forAudioFilePath: filePath,
            includeFolderMetadata: includeFolderMetadata
        )
        var usedSidecarPath: String?
        var metadata: LocalBookMetadata? = nil

        for candidate in sidecarCandidates {
            guard fileManager.fileExists(atPath: candidate) else { continue }
            do {
                metadata = try await loadSidecarMetadata(from: candidate)
                usedSidecarPath = candidate
                AppLogger.network.info(
                    "Loaded sidecar metadata \(DiagnosticLogSanitizer.fileDescriptor(for: URL(fileURLWithPath: candidate)))"
                )
                break
            } catch {
                AppLogger.network.error(
                    "Could not load sidecar pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: URL(fileURLWithPath: candidate).standardizedFileURL.path)): \(error)"
                )
            }
        }

        if metadata == nil {
            do {
                metadata = try await extractAudioMetadata(from: filePath)
                AppLogger.network.info("Extracted metadata \(DiagnosticLogSanitizer.fileDescriptor(for: url))")
            } catch {
                AppLogger.network.error("Could not extract metadata from file: \(error)")
                metadata = try createBasicMetadata(from: fileName)
            }
        }

        if metadata?.coverImagePath?.isEmpty != false {
            metadata?.coverImagePath = companionCoverPath(
                forAudioFilePath: filePath,
                includeFolderCover: includeFolderMetadata
            )
        }

        return LocalBookFile(
            id: stableId,
            fileName: fileName,
            filePath: filePath,
            relativePath: relativePath,
            fileSize: fileSize.int64Value,
            format: fileExtension,
            fileHash: fileHash,
            metadata: metadata,
            sidecarPath: usedSidecarPath,
            extractedAt: Date()
        )
    }

    func saveMetadataSidecar(
        for bookFile: LocalBookFile,
        metadata: LocalBookMetadata
    ) async throws {
        let sidecarPath = LocalBookFile.sidecarPath(for: bookFile.filePath)

        let sidecar = LocalBookSidecar(
            metadata: metadata,
            fileHash: bookFile.fileHash ?? "",
            fileName: bookFile.fileName,
            format: bookFile.format
        )

        let data = try encodeSidecar(sidecar)
        try data.write(to: URL(fileURLWithPath: sidecarPath), options: [.atomic])

        AppLogger.network.info(
            "Saved metadata sidecar \(DiagnosticLogSanitizer.fileDescriptor(for: URL(fileURLWithPath: sidecarPath)))"
        )
    }

    private func loadSidecar(from sidecarPath: String) async throws -> LocalBookSidecar {
        try Task.checkCancellation()
        let data = try Data(contentsOf: URL(fileURLWithPath: sidecarPath))
        return try decodeSidecar(from: data)
    }

    private func encodeSidecar(_ sidecar: LocalBookSidecar) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(sidecar)
    }

    func decodeSidecar(from data: Data) throws -> LocalBookSidecar {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LocalBookSidecar.self, from: data)
    }

    func updateBookMetadata(
        bookFile: LocalBookFile,
        metadata: LocalBookMetadata,
        embedIntoFile: Bool = false,
        libraryId: String? = nil
    ) async throws -> LocalBookFile {
        try await withSecurityScopedAccess(libraryId: libraryId) {
            try await saveMetadataSidecar(for: bookFile, metadata: metadata)

            if embedIntoFile {
                AppLogger.network.info(
                    "Begin file embed file=\(DiagnosticLogSanitizer.fileDescriptor(for: URL(fileURLWithPath: bookFile.filePath))) format=\(bookFile.format) titleDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: metadata.title))"
                )
                try await audioMetadataEmbedder.embed(metadata: metadata, intoAudioFileAtPath: bookFile.filePath)
                AppLogger.network.info(
                    "Embedded metadata into file \(DiagnosticLogSanitizer.fileDescriptor(for: URL(fileURLWithPath: bookFile.filePath)))"
                )
            }
        }

        var updated = bookFile
        updated.metadata = metadata
        return updated
    }

    private func withSecurityScopedAccess<T>(libraryId: String?, _ work: () async throws -> T) async throws -> T {
        guard let libraryId else {
            return try await work()
        }

        guard let bookmarkData = LocalLibraryStorageStore.shared.loadBookmark(for: libraryId) else {
            return try await work()
        }

        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            return try await work()
        }

        let isAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }

        return try await work()
    }

    func rescanBookMetadata(filePath: String, libraryId: String) async throws -> LocalBookMetadata? {
        AppLogger.network.info(
            "Rescanning metadata fileDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: URL(fileURLWithPath: filePath).standardizedFileURL.path)) libraryDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: libraryId))"
        )

        var bookmarkURL: URL?
        var isAccessingResource = false

        if let bookmarkData = LocalLibraryStorageStore.shared.loadBookmark(for: libraryId) {
            AppLogger.network.info("Found security bookmark for library")
            var isStale = false
            do {
                bookmarkURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withoutUI,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if let url = bookmarkURL {
                    isAccessingResource = url.startAccessingSecurityScopedResource()
                    AppLogger.network.info("Started accessing security-scoped resource: \(isAccessingResource)")

                    if isStale {
                        AppLogger.network.info("Bookmark is stale, may need to re-select folder")
                    }
                }
            } catch {
                AppLogger.network.error("Failed to resolve bookmark: \(error)")
            }
        } else {
            AppLogger.network.info(
                "No security bookmark found for libraryDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: libraryId))"
            )
        }

        defer {
            if isAccessingResource, let url = bookmarkURL {
                url.stopAccessingSecurityScopedResource()
                AppLogger.network.info("Stopped accessing security-scoped resource")
            }
        }

        guard fileManager.fileExists(atPath: filePath) else {
            AppLogger.network.warning(
                "File not found pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: URL(fileURLWithPath: filePath).standardizedFileURL.path))"
            )
            throw LocalLibraryError.metadataExtractionFailed
        }

        AppLogger.network.info("Audio file exists, searching for sidecars...")

        let fileURL = URL(fileURLWithPath: filePath)
        let directory = fileURL.deletingLastPathComponent()
        let bookBaseName = fileURL.deletingPathExtension().lastPathComponent

        AppLogger.network.info(
            "Scanning metadata directory pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: directory.standardizedFileURL.path)) bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookBaseName))"
        )

        guard let fileURLs = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            AppLogger.network.info("Could not read directory contents, falling back to audio extraction")
            let extractedMetadata = try await extractAudioMetadata(from: filePath)
            AppLogger.network.info("Extracted metadata from audio file")
            return extractedMetadata
        }

        let jsonFiles = fileURLs.filter { $0.pathExtension.lowercased() == "json" }
        AppLogger.network.info("Found \(jsonFiles.count) JSON files in directory")

        var metadataFound: LocalBookMetadata?

        for jsonFile in jsonFiles {
            let jsonFileName = jsonFile.deletingPathExtension().lastPathComponent
            AppLogger.network.debug("Checking metadata \(DiagnosticLogSanitizer.fileDescriptor(for: jsonFile))")

            let similarity = calculateNameSimilarity(jsonFileName, bookBaseName)
            AppLogger.network.info("Similarity score: \(String(format: "%.2f", similarity))")

            let isFolderMetadata = ["metadata", "metadata.abs", "info", "book", "audiobook"].contains(jsonFileName.lowercased())

            if similarity > 0.5 || isFolderMetadata {
                AppLogger.network.debug("Attempting metadata load \(DiagnosticLogSanitizer.fileDescriptor(for: jsonFile))")
                do {
                    let metadata = try await loadSidecarMetadata(from: jsonFile.path)
                    AppLogger.network.info("Successfully loaded metadata!")
                    metadataFound = metadata
                    break
                } catch {
                    AppLogger.network.error("Could not parse as metadata: \(error.localizedDescription)")
                }
            }
        }

        if let metadata = metadataFound {
            return metadata
        }

        AppLogger.network.info("No matching JSON files found, extracting from audio file...")

        do {
            let extractedMetadata = try await extractAudioMetadata(from: filePath)
            AppLogger.network.info("Extracted metadata from audio file")
            return extractedMetadata
        } catch {
            AppLogger.network.error("Could not extract metadata from file: \(error)")
            throw error
        }
    }

    private nonisolated func calculateNameSimilarity(_ name1: String, _ name2: String) -> Double {
        let normalized1 = name1.lowercased()
        let normalized2 = name2.lowercased()

        if normalized1 == normalized2 {
            return 1.0
        }

        if normalized1.contains(normalized2) || normalized2.contains(normalized1) {
            return 0.8
        }

        let prefixLength = min(20, min(normalized1.count, normalized2.count))
        if prefixLength > 0 {
            let prefix1 = String(normalized1.prefix(prefixLength))
            let prefix2 = String(normalized2.prefix(prefixLength))
            if prefix1 == prefix2 {
                return 0.7
            }
        }

        let distance = levenshteinDistance(normalized1, normalized2)
        let maxLength = max(normalized1.count, normalized2.count)
        guard maxLength > 0 else { return 0.0 }

        return 1.0 - (Double(distance) / Double(maxLength))
    }

    private nonisolated func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let s1Array = Array(s1)
        let s2Array = Array(s2)

        var matrix = [[Int]](repeating: [Int](repeating: 0, count: s2Array.count + 1), count: s1Array.count + 1)

        for i in 0...s1Array.count {
            matrix[i][0] = i
        }

        for j in 0...s2Array.count {
            matrix[0][j] = j
        }

        for i in 1...s1Array.count {
            for j in 1...s2Array.count {
                if s1Array[i - 1] == s2Array[j - 1] {
                    matrix[i][j] = matrix[i - 1][j - 1]
                } else {
                    matrix[i][j] = min(
                        matrix[i - 1][j] + 1,
                        matrix[i][j - 1] + 1,
                        matrix[i - 1][j - 1] + 1
                    )
                }
            }
        }

        return matrix[s1Array.count][s2Array.count]
    }

    private func extractAudioMetadata(from filePath: String) async throws -> LocalBookMetadata {
        try await metadataExtractor.extractMetadata(
            from: filePath,
            timeout: ImportLimits.metadataExtractionTimeoutSeconds
        )
    }

    private func calculateFileHash(filePath: String) throws -> String {
        try Task.checkCancellation()
        let url = URL(fileURLWithPath: filePath)
        try ImportLimits.validateImportedMediaFile(url)

        if let fileSize = try? fileManager.attributesOfItem(atPath: filePath)[.size] as? NSNumber,
            fileSize.int64Value > 10_000_000
        {
            return try calculateStreamingHash(for: url)
        }

        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func calculateStreamingHash(for url: URL) throws -> String {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let chunkSize = 1024 * 1024

        while true {
            try Task.checkCancellation()
            let chunk = fileHandle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private func createBasicMetadata(from fileName: String) throws -> LocalBookMetadata {
        let baseName = (fileName as NSString).deletingPathExtension

        var title = baseName
        var author: String? = nil

        if baseName.contains(" - ") {
            let parts = baseName.components(separatedBy: " - ")
            if parts.count == 2 {
                let firstPart = parts[0].trimmingCharacters(in: .whitespaces)
                let secondPart = parts[1].trimmingCharacters(in: .whitespaces)

                if firstPart.count < secondPart.count {
                    author = firstPart
                    title = secondPart
                } else {
                    title = firstPart
                    author = secondPart
                }
            }
        }

        return LocalBookMetadata(
            title: title,
            author: author,
            lastUpdated: Date()
        )
    }

    func getBooks(from library: LocalLibrary) async throws -> [LocalBookFile] {
        return []
    }

    struct FileSharingIngestResult: Sendable {
        var movedFiles: Int = 0
        var movedFolders: Int = 0
        var skippedItems: Int = 0
        var errors: Int = 0

        nonisolated var movedItems: Int { movedFiles + movedFolders }
        nonisolated var didMoveAnything: Bool { movedItems > 0 }
    }

    func ingestFileSharingPendingItems() async throws -> FileSharingIngestResult {
        var result = FileSharingIngestResult()

        let documentsURL = LocalLibraryService.fileSharingRootURL
        let canonicalRoot = canonicalLibraryRoot
        let inboxURL = documentsURL.appendingPathComponent("Inbox", isDirectory: true)

        AppLogger.network.info("Starting file-sharing ingest...")
        AppLogger.network.info(
            "File-sharing roots documentsDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: documentsURL.standardizedFileURL.path)) canonicalDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: canonicalRoot.standardizedFileURL.path)) inboxDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: inboxURL.standardizedFileURL.path))"
        )

        if !fileManager.fileExists(atPath: canonicalRoot.path) {
            try fileManager.createDirectory(at: canonicalRoot, withIntermediateDirectories: true)
            AppLogger.network.info("Created canonical folder")
        }

        var ingestBudget = ImportScanBudget()

        do {
            let rootItems = try fileManager.contentsOfDirectory(
                at: documentsURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            AppLogger.network.info("Documents has \(rootItems.count) items")

            for item in rootItems {
                try Task.checkCancellation()
                if item.standardizedFileURL.path == canonicalRoot.standardizedFileURL.path {
                    AppLogger.network.warning("Skipping canonical folder")
                    continue
                }
                if item.lastPathComponent == "Inbox" {
                    AppLogger.network.warning("Skipping Inbox")
                    continue
                }
                if shouldIgnoreFileSharingItem(item) {
                    result.skippedItems += 1
                    continue
                }

                AppLogger.network.debug("Checking file-sharing item pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: item.standardizedFileURL.path))")
                do {
                    try ingestSingleFileSharingItem(item, destinationRoot: canonicalRoot, result: &result, budget: &ingestBudget)
                } catch {
                    result.errors += 1
                    AppLogger.network.error(
                        "Ingest failed pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: item.standardizedFileURL.path)): \(error)"
                    )
                }
            }
        } catch {
            result.errors += 1
            AppLogger.network.error("Could not enumerate Documents folder: \(error)")
        }

        if fileManager.fileExists(atPath: inboxURL.path) {
            do {
                let inboxItems = try fileManager.contentsOfDirectory(
                    at: inboxURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
                for item in inboxItems {
                    try Task.checkCancellation()
                    if shouldIgnoreFileSharingItem(item) {
                        result.skippedItems += 1
                        continue
                    }
                    do {
                        try ingestSingleFileSharingItem(item, destinationRoot: canonicalRoot, result: &result, budget: &ingestBudget)
                    } catch {
                        result.errors += 1
                        AppLogger.network.error(
                            "Inbox ingest failed pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: item.standardizedFileURL.path)): \(error)"
                        )
                    }
                }

                let remaining =
                    (try? fileManager.contentsOfDirectory(at: inboxURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
                    ?? []
                if remaining.isEmpty {
                    try? fileManager.removeItem(at: inboxURL)
                }
            } catch {
                result.errors += 1
                AppLogger.network.error("Could not enumerate Inbox for file-sharing ingest: \(error)")
            }
        }

        if result.didMoveAnything {
            AppLogger.network.error(
                "File Sharing ingest complete: moved \(result.movedItems) items (files: \(result.movedFiles), folders: \(result.movedFolders)), skipped \(result.skippedItems), errors \(result.errors)"
            )
        }

        return result
    }

    private nonisolated func shouldIgnoreFileSharingItem(_ url: URL) -> Bool {
        let name = url.lastPathComponent

        if name.hasPrefix(".") { return true }
        if name == ".DS_Store" { return true }
        if name == "Thumbs.db" { return true }
        if name == "desktop.ini" { return true }

        let systemNames: Set<String> = [
            "Metadata",
            "DownloadQueues",
            "Individual_Audiobooks",
            "Inbox",
            "PlaybackState",
            "Audiobooks",
            "Ebooks",
            "ListeningStats",
        ]
        if systemNames.contains(name) { return true }

        if name.hasSuffix(".store") || name.hasSuffix(".store-wal") || name.hasSuffix(".store-shm") { return true }

        if name.hasPrefix("enve_") && name.hasSuffix(".json") { return true }
        if name.hasSuffix(".json.bak") { return true }

        return false
    }

    private func ingestSingleFileSharingItem(
        _ item: URL,
        destinationRoot: URL,
        result: inout FileSharingIngestResult,
        budget: inout ImportScanBudget
    ) throws {
        try budget.record(url: item, root: LocalLibraryService.fileSharingRootURL)
        let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

        if isDirectory {
            try ingestFolderItem(item, destinationRoot: destinationRoot, result: &result, budget: &budget)
            return
        }

        if isAudioFile(item) {
            try ImportLimits.validateImportedMediaFile(item)
            let destURL = uniqueDestinationURL(for: destinationRoot.appendingPathComponent(item.lastPathComponent))
            AppLogger.network.info(
                "Moving audio sourceDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: item.standardizedFileURL.path)) destinationDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: destURL.standardizedFileURL.path))"
            )
            try moveItem(at: item, to: destURL)
            result.movedFiles += 1

            for sidecarPath in fileSpecificSidecarCandidates(forAudioURL: item) {
                let sidecarURL = URL(fileURLWithPath: sidecarPath)
                guard fileManager.fileExists(atPath: sidecarURL.path) else { continue }
                guard
                    sidecarURL.deletingLastPathComponent().standardizedFileURL.path
                        == item.deletingLastPathComponent().standardizedFileURL.path
                else { continue }

                let destSidecarURL = uniqueDestinationURL(for: destinationRoot.appendingPathComponent(sidecarURL.lastPathComponent))
                try? moveItem(at: sidecarURL, to: destSidecarURL)
            }
            return
        }

        if isEbookFile(item) {
            try ImportLimits.validateImportedMediaFile(item)
            let ebooksRoot = canonicalEbooksRoot
            try? fileManager.createDirectory(at: ebooksRoot, withIntermediateDirectories: true)
            let destURL = uniqueDestinationURL(for: ebooksRoot.appendingPathComponent(item.lastPathComponent))
            AppLogger.network.info(
                "Moving ebook sourceDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: item.standardizedFileURL.path)) destinationDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: destURL.standardizedFileURL.path))"
            )
            try moveItem(at: item, to: destURL)
            result.movedFiles += 1
            return
        }

        result.skippedItems += 1
    }

    private func ingestFolderItem(
        _ folderURL: URL,
        destinationRoot: URL,
        result: inout FileSharingIngestResult,
        budget: inout ImportScanBudget
    ) throws {
        let contents =
            (try? fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        let hasTopLevelAudio = contents.contains(where: { isAudioFile($0) })
        let hasTopLevelEbook = contents.contains(where: { isEbookFile($0) })
        let hasSubfolders = contents.contains(where: { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) == true }
        )

        if !hasTopLevelAudio && !hasTopLevelEbook && hasSubfolders {
            for child in contents {
                if shouldIgnoreFileSharingItem(child) { continue }
                do {
                    try ingestSingleFileSharingItem(child, destinationRoot: destinationRoot, result: &result, budget: &budget)
                } catch {
                    result.errors += 1
                    AppLogger.network.error(
                        "Failed ingesting nested itemDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: child.standardizedFileURL.path)) folderDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: folderURL.standardizedFileURL.path)): \(error)"
                    )
                }
            }

            let remaining =
                (try? fileManager.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            if remaining.isEmpty {
                try? fileManager.removeItem(at: folderURL)
            }
            return
        }

        try validateFolderForIngest(folderURL, budget: &budget)
        let destFolderURL = uniqueDestinationURL(
            for: destinationRoot.appendingPathComponent(folderURL.lastPathComponent, isDirectory: true)
        )
        AppLogger.network.info(
            "Moving folder sourceDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: folderURL.standardizedFileURL.path)) destinationDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: destFolderURL.standardizedFileURL.path))"
        )
        try moveItem(at: folderURL, to: destFolderURL)
        result.movedFolders += 1
    }

    private func validateFolderForIngest(_ folderURL: URL, budget: inout ImportScanBudget) throws {
        guard
            let enumerator = fileManager.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return }

        for case let item as URL in enumerator {
            try budget.record(url: item, root: folderURL)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDirectory else { continue }
            if isAudioFile(item) || isEbookFile(item) {
                try ImportLimits.validateImportedMediaFile(item)
            }
        }
    }

    private nonisolated func isAudioFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return AudiobookFormat.from(fileExtension: ext) != nil
    }

    private nonisolated func isEbookFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return EbookFormat.from(fileExtension: ext) != nil
    }

    private nonisolated var canonicalEbooksRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Ebooks/local", isDirectory: true)
    }

    private nonisolated var serverDownloadedEbooksRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Ebooks", isDirectory: true)
    }

    private nonisolated func fileSpecificSidecarCandidates(forAudioURL audioURL: URL) -> [String] {
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        let fullName = audioURL.lastPathComponent
        let dir = audioURL.deletingLastPathComponent()

        return [
            dir.appendingPathComponent("\(baseName).sidecar.json").path,
            dir.appendingPathComponent("\(baseName)._sidecar.json").path,
            dir.appendingPathComponent("\(fullName)._sidecar.json").path,
            dir.appendingPathComponent("\(baseName).metadata.json").path,
            dir.appendingPathComponent("\(fullName).metadata.json").path,
            dir.appendingPathComponent("\(baseName).json").path,
            dir.appendingPathComponent("\(fullName).json").path,
            dir.appendingPathComponent("\(baseName).chapters.json").path,
            dir.appendingPathComponent("\(fullName).chapters.json").path,
        ]
    }

    private func uniqueDestinationURL(for desired: URL) -> URL {
        if !fileManager.fileExists(atPath: desired.path) {
            return desired
        }

        let dir = desired.deletingLastPathComponent()
        let base = desired.deletingPathExtension().lastPathComponent
        let ext = desired.pathExtension

        var counter = 1
        while true {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(base) (\(counter))"
            } else {
                candidateName = "\(base) (\(counter)).\(ext)"
            }
            let candidate = dir.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    private func moveItem(at src: URL, to dst: URL) throws {
        do {
            try fileManager.moveItem(at: src, to: dst)
        } catch {
            try fileManager.copyItem(at: src, to: dst)
            try? fileManager.removeItem(at: src)
        }
    }

    private var canonicalLibraryRoot: URL {
        fileSharingAudiobooksFolder
    }

    func scanCanonicalLibrary(libraryId: String = LocalLibraryService.fileSharingLibraryId) async throws -> LocalLibraryScanResult {
        let startTime = Date()

        let documentsRoot = LocalLibraryService.fileSharingRootURL
        AppLogger.network.info("Scanning file-sharing library...")
        AppLogger.network.info(
            "Scanning file-sharing roots documentsDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: documentsRoot.standardizedFileURL.path)) canonicalDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: canonicalLibraryRoot.standardizedFileURL.path))"
        )

        if !fileManager.fileExists(atPath: canonicalLibraryRoot.path) {
            try fileManager.createDirectory(at: canonicalLibraryRoot, withIntermediateDirectories: true)
            AppLogger.network.info("Created canonical folder")
        }

        var booksFound: [LocalBookFile] = []
        var skippedFiles: [String] = []
        var scanBudget = ImportScanBudget()

        if let rootItems = try? fileManager.contentsOfDirectory(
            at: documentsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            AppLogger.network.info("Documents root has \(rootItems.count) items")
            for item in rootItems {
                try await scanBudget.recordAsync(url: item, root: documentsRoot)
                if item.standardizedFileURL.path == canonicalLibraryRoot.standardizedFileURL.path { continue }
                if item.lastPathComponent == "Inbox" { continue }
                if item.lastPathComponent.hasPrefix(".") { continue }
                if shouldIgnoreFileSharingItem(item) { continue }

                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                if !isDirectory {
                    let ext = item.pathExtension.lowercased()
                    if AudiobookFormat.from(fileExtension: ext) != nil {
                        AppLogger.network.debug("Found audio \(DiagnosticLogSanitizer.fileDescriptor(for: item))")
                        if let bookFile = try? await processStandaloneAudioFile(item) {
                            booksFound.append(bookFile)
                            AppLogger.network.info("Processed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                        }
                    } else if EbookFormat.from(fileExtension: ext) != nil {
                        AppLogger.network.debug("Found ebook \(DiagnosticLogSanitizer.fileDescriptor(for: item))")
                        if let bookFile = try? await processStandaloneEbookFile(item) {
                            booksFound.append(bookFile)
                            AppLogger.network.info("Processed ebookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                        }
                    }
                } else {
                    if let folderContents = try? fileManager.contentsOfDirectory(
                        at: item,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    ) {
                        let hasAudio = folderContents.contains { AudiobookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil }
                        let hasEbook = folderContents.contains { EbookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil }
                        let imageFiles = folderContents.filter { EbookFormat.isImagePageExtension($0.pathExtension.lowercased()) }
                        if hasAudio {
                            AppLogger.network.debug("Found book folder pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: item.standardizedFileURL.path))")
                            if let bookFile = try? await processCanonicalBookFolder(item, authorName: "Unknown Author") {
                                booksFound.append(bookFile)
                                AppLogger.network.info("Processed folder bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                            }
                        } else if hasEbook {
                            AppLogger.network.debug("Found ebook folder pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: item.standardizedFileURL.path))")
                            for ebookFile in folderContents
                            where EbookFormat.from(fileExtension: ebookFile.pathExtension.lowercased()) != nil {
                                if let bookFile = try? await processStandaloneEbookFile(ebookFile) {
                                    booksFound.append(bookFile)
                                    AppLogger.network.info("Processed folder ebookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                                }
                            }
                        } else if imageFiles.count >= 2 {
                            AppLogger.network.info(
                                "Found image folder pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: item.standardizedFileURL.path)) images=\(imageFiles.count)"
                            )
                            if let bookFile = processImageFolder(item, imageFiles: imageFiles) {
                                booksFound.append(bookFile)
                                AppLogger.network.info("Processed image bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                            }
                        }
                    }
                }
            }
        }

        guard
            let rootContents = try? fileManager.contentsOfDirectory(
                at: canonicalLibraryRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            AppLogger.network.info("Could not enumerate canonical folder")
            return LocalLibraryScanResult(
                localLibraryId: libraryId,
                booksFound: booksFound,
                skippedFiles: skippedFiles,
                scanDuration: Date().timeIntervalSince(startTime),
                scannedAt: Date()
            )
        }

        AppLogger.network.info("Canonical folder has \(rootContents.count) items")

        for item in rootContents {
            try await scanBudget.recordAsync(url: item, root: canonicalLibraryRoot)
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

            if !isDirectory {
                let ext = item.pathExtension.lowercased()
                if AudiobookFormat.from(fileExtension: ext) != nil {
                    if let bookFile = try? await processStandaloneAudioFile(item) {
                        booksFound.append(bookFile)
                        AppLogger.network.info("Found standalone audiobookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                    }
                }
            }
        }

        for folder in rootContents {
            try Task.checkCancellation()
            guard let isDirectory = try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                isDirectory
            else { continue }

            let folderName = folder.lastPathComponent

            let folderContents = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            let hasAudioFiles =
                folderContents?.contains { url in
                    let ext = url.pathExtension.lowercased()
                    return AudiobookFormat.from(fileExtension: ext) != nil
                } ?? false
            let ebookFiles =
                folderContents?.filter { url in
                    EbookFormat.from(fileExtension: url.pathExtension.lowercased()) != nil
                } ?? []
            let imageFolderFiles =
                folderContents?.filter { url in
                    EbookFormat.isImagePageExtension(url.pathExtension.lowercased())
                } ?? []

            if hasAudioFiles {
                do {
                    if let bookFile = try await processCanonicalBookFolder(folder, authorName: "Unknown Author") {
                        booksFound.append(bookFile)
                        AppLogger.network.info("Found book folder diagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                    }
                } catch {
                    AppLogger.network.error(
                        "Error processing book folder pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: folder.standardizedFileURL.path)): \(error)"
                    )
                    skippedFiles.append(folder.path)
                }
            } else if !ebookFiles.isEmpty {
                for ebookFile in ebookFiles {
                    do {
                        if let bookFile = try await processStandaloneEbookFile(ebookFile),
                            !booksFound.contains(where: { $0.filePath == bookFile.filePath })
                        {
                            booksFound.append(bookFile)
                            AppLogger.network.info("Found canonical ebookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                        }
                    } catch {
                        AppLogger.network.error(
                            "Error processing ebook fileDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: ebookFile.standardizedFileURL.path)): \(error)"
                        )
                        skippedFiles.append(ebookFile.path)
                    }
                }
            } else if imageFolderFiles.count >= 2 {
                if let bookFile = processImageFolder(folder, imageFiles: imageFolderFiles),
                    !booksFound.contains(where: { $0.filePath == bookFile.filePath })
                {
                    booksFound.append(bookFile)
                    AppLogger.network.info("Found canonical image bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                }
            } else {
                guard let bookFolders = folderContents else { continue }

                for bookFolder in bookFolders {
                    try Task.checkCancellation()
                    guard let isDir = try? bookFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                        isDir
                    else { continue }

                    let nestedContents =
                        (try? fileManager.contentsOfDirectory(
                            at: bookFolder,
                            includingPropertiesForKeys: [.isDirectoryKey],
                            options: [.skipsHiddenFiles]
                        )) ?? []
                    let nestedEbookFiles = nestedContents.filter {
                        EbookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil
                    }
                    let nestedImageFiles = nestedContents.filter {
                        EbookFormat.isImagePageExtension($0.pathExtension.lowercased())
                    }

                    if !nestedEbookFiles.isEmpty {
                        for ebookFile in nestedEbookFiles {
                            do {
                                if let bookFile = try await processStandaloneEbookFile(ebookFile),
                                    !booksFound.contains(where: { $0.filePath == bookFile.filePath })
                                {
                                    booksFound.append(bookFile)
                                    AppLogger.network.info("Found legacy canonical ebookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                                }
                            } catch {
                                AppLogger.network.error(
                                    "Error processing nested ebook fileDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: ebookFile.standardizedFileURL.path)): \(error)"
                                )
                                skippedFiles.append(ebookFile.path)
                            }
                        }
                        continue
                    }

                    if nestedImageFiles.count >= 2 {
                        if let bookFile = processImageFolder(bookFolder, imageFiles: nestedImageFiles),
                            !booksFound.contains(where: { $0.filePath == bookFile.filePath })
                        {
                            booksFound.append(bookFile)
                            AppLogger.network.info("Found nested image bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                        }
                        continue
                    }

                    do {
                        if let bookFile = try await processCanonicalBookFolder(bookFolder, authorName: folderName) {
                            booksFound.append(bookFile)
                            AppLogger.network.info("Found canonical bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                        }
                    } catch {
                        AppLogger.network.error(
                            "Error processing book folder pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFolder.standardizedFileURL.path)): \(error)"
                        )
                        skippedFiles.append(bookFolder.path)
                    }
                }
            }
        }

        let scanDuration = Date().timeIntervalSince(startTime)

        let legacyAudiobooksURL = LocalLibraryService.fileSharingRootURL.appendingPathComponent("Audiobooks", isDirectory: true)
        if fileManager.fileExists(atPath: legacyAudiobooksURL.path) {
            AppLogger.network.info("Scanning legacy Audiobooks folder for backward compat…")
            if let legacyContents = try? fileManager.contentsOfDirectory(
                at: legacyAudiobooksURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for legacyItem in legacyContents {
                    try await scanBudget.recordAsync(url: legacyItem, root: legacyAudiobooksURL)
                    let isDir = (try? legacyItem.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if !isDir {
                        let ext = legacyItem.pathExtension.lowercased()
                        if AudiobookFormat.from(fileExtension: ext) != nil,
                            let bookFile = try? await processStandaloneAudioFile(legacyItem)
                        {
                            if !booksFound.contains(where: { $0.filePath == bookFile.filePath }) {
                                booksFound.append(bookFile)
                                AppLogger.network.info("Found standalone bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                            }
                        }
                    } else {
                        let subContents =
                            (try? fileManager.contentsOfDirectory(
                                at: legacyItem,
                                includingPropertiesForKeys: [.isDirectoryKey],
                                options: [.skipsHiddenFiles]
                            )) ?? []
                        let hasDirectAudio = subContents.contains {
                            AudiobookFormat.from(fileExtension: $0.pathExtension.lowercased()) != nil
                        }
                        if hasDirectAudio {
                            if let bookFile = try? await processCanonicalBookFolder(legacyItem, authorName: "Unknown Author"),
                                !booksFound.contains(where: { $0.filePath == bookFile.filePath })
                            {
                                booksFound.append(bookFile)
                                AppLogger.network.info("Found book folder diagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                            }
                        } else {
                            let authorName = legacyItem.lastPathComponent
                            for bookFolder in subContents {
                                let isBFDir = (try? bookFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                                guard isBFDir else { continue }
                                if let bookFile = try? await processCanonicalBookFolder(bookFolder, authorName: authorName),
                                    !booksFound.contains(where: { $0.filePath == bookFile.filePath })
                                {
                                    booksFound.append(bookFile)
                                    AppLogger.network.info("Found canonical bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookFile.id))")
                                }
                            }
                        }
                    }
                }
            }
        }

        let ebooksRoot = canonicalEbooksRoot
        if fileManager.fileExists(atPath: ebooksRoot.path),
            let ebookItems = try? fileManager.contentsOfDirectory(
                at: ebooksRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        {
            AppLogger.network.info(
                "Scanning local ebooks pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: ebooksRoot.standardizedFileURL.path)) items=\(ebookItems.count)"
            )
            for item in ebookItems {
                try await scanBudget.recordAsync(url: item, root: ebooksRoot)
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard !isDir else { continue }
                guard isEbookFile(item) else { continue }
                if let ebookFile = try? await processStandaloneEbookFile(item),
                    !booksFound.contains(where: { $0.filePath == ebookFile.filePath })
                {
                    booksFound.append(ebookFile)
                    AppLogger.network.debug(
                        "Found local ebookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: ebookFile.id))"
                    )
                }
            }
        }

        AppLogger.network.info("File-sharing scan complete: Found \(booksFound.count) books in \(String(format: "%.2f", scanDuration))s")

        return LocalLibraryScanResult(
            localLibraryId: libraryId,
            booksFound: booksFound,
            skippedFiles: skippedFiles,
            scanDuration: scanDuration,
            scannedAt: Date()
        )
    }

    private func processStandaloneAudioFile(_ audioURL: URL) async throws -> LocalBookFile? {
        try Task.checkCancellation()
        try ImportLimits.validateImportedMediaFile(audioURL)
        let fileName = audioURL.lastPathComponent
        let filePath = audioURL.path
        let fileExtension = audioURL.pathExtension.lowercased()

        let fileSize: Int64 = (try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) }) ?? 0

        let fileHash = try? calculateFileHash(filePath: filePath)

        var localMetadata: LocalBookMetadata? = nil
        var sidecarPath: String? = nil

        let sidecarURL = audioURL.deletingPathExtension().appendingPathExtension("sidecar.json")
        if fileManager.fileExists(atPath: sidecarURL.path) {
            do {
                localMetadata = try await loadSidecarMetadata(from: sidecarURL.path)
                sidecarPath = sidecarURL.path
                AppLogger.network.info("Loaded audio sidecar \(DiagnosticLogSanitizer.fileDescriptor(for: sidecarURL))")
            } catch {
                AppLogger.network.error("Could not load sidecar: \(error)")
            }
        }

        if localMetadata == nil {
            let audibleMetadataURL = audioURL.deletingPathExtension().appendingPathExtension("metadata.json")
            if fileManager.fileExists(atPath: audibleMetadataURL.path) {
                do {
                    localMetadata = try await loadSidecarMetadata(from: audibleMetadataURL.path)
                    sidecarPath = audibleMetadataURL.path
                    AppLogger.network.info("Loaded external audio metadata \(DiagnosticLogSanitizer.fileDescriptor(for: audibleMetadataURL))")
                } catch {
                    AppLogger.network.error("Could not load external metadata: \(error)")
                }
            }
        }

        if localMetadata == nil {
            localMetadata = try? await extractAudioMetadata(from: audioURL.path)

            if localMetadata == nil {
                localMetadata = LocalBookMetadata(
                    title: audioURL.deletingPathExtension().lastPathComponent
                )
            }
        }

        if localMetadata?.coverImagePath?.isEmpty != false {
            localMetadata?.coverImagePath = companionCoverPath(forAudioFilePath: filePath)
        }

        let stableId = "\(LocalLibraryService.fileSharingLibraryId):\(fileHash ?? UUID().uuidString)"

        return LocalBookFile(
            id: stableId,
            fileName: fileName,
            filePath: filePath,
            fileSize: fileSize,
            format: fileExtension,
            fileHash: fileHash,
            metadata: localMetadata,
            sidecarPath: sidecarPath
        )
    }

    private func processStandaloneEbookFile(_ ebookURL: URL) async throws -> LocalBookFile? {
        try Task.checkCancellation()
        try ImportLimits.validateImportedMediaFile(ebookURL)
        let stdPath = ebookURL.standardizedFileURL.path
        let serverRoot = serverDownloadedEbooksRoot.standardizedFileURL.path
        let localRoot = canonicalEbooksRoot.standardizedFileURL.path
        if stdPath.hasPrefix(serverRoot) && !stdPath.hasPrefix(localRoot) {
            AppLogger.network.warning("Skipping server-cached ebook \(DiagnosticLogSanitizer.fileDescriptor(for: ebookURL))")
            return nil
        }

        let fileName = ebookURL.lastPathComponent
        let filePath = ebookURL.path
        let fileExtension = ebookURL.pathExtension.lowercased()

        guard EbookFormat.from(fileExtension: fileExtension) != nil else { return nil }

        let fileSize: Int64 = (try? ebookURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) }) ?? 0
        let fileHash = try? calculateFileHash(filePath: filePath)
        let stableId = "\(LocalLibraryService.fileSharingLibraryId):\(fileHash ?? UUID().uuidString)"

        var localMetadata: LocalBookMetadata? = nil
        var sidecarPath: String? = nil
        let sidecarURL = ebookURL.deletingPathExtension().appendingPathExtension("sidecar.json")
        if fileManager.fileExists(atPath: sidecarURL.path) {
            do {
                localMetadata = try await loadSidecarMetadata(from: sidecarURL.path)
                sidecarPath = sidecarURL.path
                AppLogger.network.debug(
                    "Loaded ebook sidecar \(DiagnosticLogSanitizer.fileDescriptor(for: sidecarURL))"
                )
            } catch {
                AppLogger.network.error("Could not load ebook sidecar: \(error)")
            }
        }

        if localMetadata == nil {
            do {
                localMetadata = try await LocalEbookImporter.shared.extractMetadata(from: ebookURL)
                AppLogger.network.info(
                    "Extracted Readium metadata \(DiagnosticLogSanitizer.fileDescriptor(for: ebookURL))"
                )
            } catch {
                AppLogger.network.error(
                    "Readium extraction failed fileDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: ebookURL.standardizedFileURL.path)): \(error). Using filename."
                )
                localMetadata = LocalBookMetadata(
                    title: ebookURL.deletingPathExtension().lastPathComponent,
                    author: nil
                )
            }
        }

        if localMetadata != nil,
            localMetadata?.coverImagePath == nil || !(fileManager.fileExists(atPath: localMetadata?.coverImagePath ?? ""))
        {
            let coverURL = ebookURL.deletingPathExtension().appendingPathExtension("cover.jpg")
            if fileManager.fileExists(atPath: coverURL.path) {
                localMetadata?.coverImagePath = coverURL.path
            } else {
                let extracted = try? await LocalEbookImporter.shared.extractMetadata(from: ebookURL)
                if let extractedCover = extracted?.coverImagePath, fileManager.fileExists(atPath: extractedCover) {
                    localMetadata?.coverImagePath = extractedCover
                    if localMetadata?.title == ebookURL.deletingPathExtension().lastPathComponent,
                        let betterTitle = extracted?.title, betterTitle != localMetadata?.title
                    {
                        localMetadata?.title = betterTitle
                    }
                    if localMetadata?.author == nil { localMetadata?.author = extracted?.author }
                }
            }
        }

        if let localMetadata, sidecarPath == nil {
            let sidecar = LocalBookSidecar(
                metadata: localMetadata,
                fileHash: fileHash ?? UUID().uuidString,
                fileName: fileName,
                format: fileExtension
            )
            let sidecarURL = URL(fileURLWithPath: LocalBookFile.sidecarPath(for: filePath))
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(sidecar)
                try data.write(to: sidecarURL, options: .atomic)
                sidecarPath = sidecarURL.path
                AppLogger.network.info(
                    "Saved ebook sidecar \(DiagnosticLogSanitizer.fileDescriptor(for: sidecarURL))"
                )
            } catch {
                AppLogger.network.error(
                    "Failed to save ebook sidecar pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: sidecarURL.standardizedFileURL.path)): \(error)"
                )
            }
        }

        return LocalBookFile(
            id: stableId,
            fileName: fileName,
            filePath: filePath,
            fileSize: fileSize,
            format: fileExtension,
            fileHash: fileHash,
            metadata: localMetadata,
            sidecarPath: sidecarPath
        )
    }

    private nonisolated func processImageFolder(_ folderURL: URL, imageFiles: [URL]) -> LocalBookFile? {
        let folderName = folderURL.lastPathComponent
        let folderPath = folderURL.path

        let sortedImages = imageFiles.sorted { a, b in
            a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }

        guard !sortedImages.isEmpty else { return nil }

        let totalSize = sortedImages.reduce(Int64(0)) { total, url in
            total + (Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }

        let stableId = "\(LocalLibraryService.fileSharingLibraryId):imagefolder:\(deterministicHash(canonicalLocalPath(folderPath)))"

        var localMetadata: LocalBookMetadata? = nil
        var sidecarPath: String? = nil
        let sidecarURL = folderURL.appendingPathComponent("metadata.json")
        if FileManager.default.fileExists(atPath: sidecarURL.path) {
            if let data = try? Data(contentsOf: sidecarURL),
                let decoded = try? JSONDecoder().decode(LocalBookMetadata.self, from: data)
            {
                localMetadata = decoded
                sidecarPath = sidecarURL.path
            }
        }

        if localMetadata == nil {
            let parentName = folderURL.deletingLastPathComponent().lastPathComponent
            let author = (parentName != "Individual_Audiobooks" && parentName != "Documents") ? parentName : nil
            localMetadata = LocalBookMetadata(
                title: folderName,
                author: author
            )
        }

        let coverNames = ["cover", "front", "folder", "thumbnail"]
        let coverPath: String? =
            sortedImages.first(where: { img in
                let name = img.deletingPathExtension().lastPathComponent.lowercased()
                return coverNames.contains(where: { name.contains($0) })
            })?.path ?? sortedImages.first?.path

        localMetadata?.coverImagePath = coverPath

        return LocalBookFile(
            id: stableId,
            fileName: folderName,
            filePath: folderPath,
            fileSize: totalSize,
            format: EbookFormat.imagefolder.rawValue,
            metadata: localMetadata,
            sidecarPath: sidecarPath
        )
    }

    private func processCanonicalBookFolder(_ folderURL: URL, authorName: String) async throws -> LocalBookFile? {
        try Task.checkCancellation()
        let contents = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        var folderBudget = ImportScanBudget()
        for item in contents {
            try await folderBudget.recordAsync(url: item, root: folderURL)
        }

        let audioFiles = contents.filter { url in
            let ext = url.pathExtension.lowercased()
            return AudiobookFormat.from(fileExtension: ext) != nil
        }

        guard !audioFiles.isEmpty else {
            return nil
        }

        var metadata: LocalBookMetadata?
        var sidecarPath: String?

        let metadataURL = folderURL.appendingPathComponent("metadata.json")
        if fileManager.fileExists(atPath: metadataURL.path) {
            do {
                metadata = try await loadSidecarMetadata(from: metadataURL.path)
                sidecarPath = metadataURL.path
                AppLogger.network.info("Loaded folder metadata \(DiagnosticLogSanitizer.fileDescriptor(for: metadataURL))")
            } catch {
                AppLogger.network.error("Could not load metadata.json: \(error)")
            }
        }

        let coverExtensions = ["jpg", "jpeg", "png", "webp"]
        var discoveredCoverPath: String?
        let needsCoverLookup =
            metadata?.coverImagePath == nil
            || !(fileManager.fileExists(atPath: metadata?.coverImagePath ?? ""))
        if needsCoverLookup {
            if let coverFile = contents.first(where: { url in
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                let ext = url.pathExtension.lowercased()
                return coverExtensions.contains(ext)
                    && (name == "cover" || name == "folder" || name.contains("artwork") || name.contains("cover"))
            }) {
                discoveredCoverPath = coverFile.path
            }
        }

        if audioFiles.count == 1 {
            let audioFile = audioFiles[0]
            try ImportLimits.validateImportedMediaFile(audioFile)
            let fileName = audioFile.lastPathComponent
            let filePath = audioFile.path
            let fileExtension = audioFile.pathExtension.lowercased()

            let fileSize: Int64 = (try? audioFile.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) }) ?? 0

            let fileHash = try? calculateFileHash(filePath: filePath)

            if metadata == nil {
                let sidecarURL = audioFile.deletingPathExtension().appendingPathExtension("sidecar.json")
                if fileManager.fileExists(atPath: sidecarURL.path) {
                    do {
                        metadata = try await loadSidecarMetadata(from: sidecarURL.path)
                        sidecarPath = sidecarURL.path
                        AppLogger.network.info("Loaded audio sidecar \(DiagnosticLogSanitizer.fileDescriptor(for: sidecarURL))")
                    } catch {
                        AppLogger.network.error("Could not load sidecar: \(error)")
                    }
                }
            }

            if metadata == nil {
                let audibleMetadataURL = audioFile.deletingPathExtension().appendingPathExtension("metadata.json")
                if fileManager.fileExists(atPath: audibleMetadataURL.path) {
                    do {
                        metadata = try await loadSidecarMetadata(from: audibleMetadataURL.path)
                        sidecarPath = audibleMetadataURL.path
                        AppLogger.network.info("Loaded external audio metadata \(DiagnosticLogSanitizer.fileDescriptor(for: audibleMetadataURL))")
                    } catch {
                        AppLogger.network.error("Could not load external metadata: \(error)")
                    }
                }
            }

            if metadata == nil {
                do {
                    metadata = try await extractAudioMetadata(from: filePath)
                } catch {
                    metadata = try createBasicMetadata(from: fileName)
                }
            }

            if metadata?.author == nil || metadata?.author?.isEmpty == true {
                metadata?.author = authorName
            }

            if metadata?.title == nil || metadata?.title.isEmpty == true {
                metadata?.title = folderURL.lastPathComponent
            }

            if metadata?.coverImagePath?.isEmpty != false {
                metadata?.coverImagePath = discoveredCoverPath
            }

            let stableId = "\(LocalLibraryService.fileSharingLibraryId):\(fileHash ?? "unknown")"

            return LocalBookFile(
                id: stableId,
                fileName: fileName,
                filePath: filePath,
                fileSize: fileSize,
                format: fileExtension,
                fileHash: fileHash,
                metadata: metadata,
                sidecarPath: sidecarPath,
                extractedAt: Date()
            )
        }

        AppLogger.network.info(
            "Processing multi-file audiobook folderDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: folderURL.standardizedFileURL.path)) files=\(audioFiles.count)"
        )

        let sortedFiles = sortAudioFilesByTrackOrder(audioFiles)

        var audioFileInfos: [AudioFileInfo] = []
        var totalDuration: TimeInterval = 0
        var totalSize: Int64 = 0
        var primaryMetadata: LocalBookMetadata? = metadata

        for (index, audioFile) in sortedFiles.enumerated() {
            try Task.checkCancellation()
            try ImportLimits.validateImportedMediaFile(audioFile.url)
            let fileName = audioFile.url.lastPathComponent
            let filePath = audioFile.url.path
            let fileExtension = audioFile.url.pathExtension.lowercased()

            let fileSize: Int64 = (try? audioFile.url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) }) ?? 0
            totalSize += fileSize

            var fileDuration: TimeInterval = 0
            var fileTitle: String? = nil

            do {
                let asset = AVURLAsset(url: audioFile.url)
                fileDuration = try await asset.load(.duration).seconds

                let commonMetadata = try? await asset.load(.commonMetadata)
                if let titleItem = commonMetadata?.first(where: { $0.commonKey == .commonKeyTitle }),
                    let title = try? await titleItem.load(.stringValue)
                {
                    fileTitle = title
                }

                if index == 0 && primaryMetadata == nil {
                    primaryMetadata = try? await extractAudioMetadata(from: filePath)
                }
            } catch {
                AppLogger.network.error(
                    "Could not load duration \(DiagnosticLogSanitizer.fileDescriptor(for: URL(fileURLWithPath: filePath))): \(error)"
                )
            }

            let audioFileInfo = AudioFileInfo(
                id: "\(LocalLibraryService.fileSharingLibraryId):\(deterministicHash(canonicalLocalPath(filePath)))",
                fileName: fileName,
                filePath: filePath,
                fileSize: fileSize,
                format: fileExtension,
                duration: fileDuration,
                trackNumber: audioFile.trackNumber,
                title: fileTitle ?? (fileName as NSString).deletingPathExtension
            )
            audioFileInfos.append(audioFileInfo)
            totalDuration += fileDuration
        }

        let primaryFile = sortedFiles[0]
        let primaryFilePath = primaryFile.url.path
        let primaryFileExtension = primaryFile.url.pathExtension.lowercased()

        let combinedHash = calculateCombinedHash(for: audioFileInfos)

        if primaryMetadata == nil {
            primaryMetadata = LocalBookMetadata(title: folderURL.lastPathComponent)
        }
        if primaryMetadata?.coverImagePath?.isEmpty != false {
            primaryMetadata?.coverImagePath = discoveredCoverPath
        }
        primaryMetadata?.duration = totalDuration

        if primaryMetadata?.author == nil || primaryMetadata?.author?.isEmpty == true {
            primaryMetadata?.author = authorName
        }

        if primaryMetadata?.title == nil || primaryMetadata?.title.isEmpty == true
            || primaryMetadata?.title == primaryFile.url.deletingPathExtension().lastPathComponent
        {
            primaryMetadata?.title = folderURL.lastPathComponent
        }

        if primaryMetadata?.chapters == nil || primaryMetadata?.chapters?.isEmpty == true {
            var chapters: [LocalChapter] = []
            var cumulativeOffset: TimeInterval = 0

            for (index, file) in audioFileInfos.enumerated() {
                let duration = file.duration ?? 0
                let chapterTitle = file.title ?? (file.fileName as NSString).deletingPathExtension

                let chapter = LocalChapter(
                    id: "ch_\(index)",
                    title: chapterTitle,
                    startTime: cumulativeOffset,
                    endTime: cumulativeOffset + duration,
                    duration: duration
                )
                chapters.append(chapter)
                cumulativeOffset += duration
            }

            if !chapters.isEmpty {
                primaryMetadata?.chapters = chapters
                AppLogger.network.info("Auto-generated \(chapters.count) chapters from multi-file audiobook")
            }
        }

        let stableId =
            "\(LocalLibraryService.fileSharingLibraryId):\(combinedHash ?? deterministicHash(canonicalLocalPath(folderURL.path)))"

        AppLogger.network.info(
            "Created multi-file audiobook bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: stableId)) tracks=\(audioFileInfos.count) duration=\(Int(totalDuration))s"
        )

        return LocalBookFile(
            id: stableId,
            fileName: primaryFile.url.lastPathComponent,
            filePath: primaryFilePath,
            relativePath: nil,
            fileSize: totalSize,
            format: primaryFileExtension,
            fileHash: combinedHash,
            metadata: primaryMetadata,
            sidecarPath: sidecarPath,
            extractedAt: Date(),
            audioFiles: audioFileInfos
        )
    }

    private nonisolated func sortAudioFilesByTrackOrder(_ files: [URL]) -> [(url: URL, trackNumber: Int?)] {
        let filesWithTrackNumbers = files.map { url -> (url: URL, trackNumber: Int?) in
            let trackNumber = extractTrackNumber(from: url.lastPathComponent)
            return (url: url, trackNumber: trackNumber)
        }

        return filesWithTrackNumbers.sorted { a, b in
            if let tn1 = a.trackNumber, let tn2 = b.trackNumber {
                return tn1 < tn2
            }
            return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
    }

    func moveToCanonicalLibrary(bookFile: LocalBookFile) async throws -> LocalBookFile {
        guard let metadata = bookFile.metadata else {
            throw LocalLibraryError.metadataExtractionFailed
        }

        let author = metadata.author ?? "Unknown Author"
        let title = metadata.title

        let safeAuthor = sanitizeFilename(author)
        let safeTitle = sanitizeFilename(title)

        let bookFolder =
            canonicalLibraryRoot
            .appendingPathComponent(safeAuthor)
            .appendingPathComponent(safeTitle)

        try fileManager.createDirectory(at: bookFolder, withIntermediateDirectories: true)

        let sourceURL = URL(fileURLWithPath: bookFile.filePath)
        let destURL = bookFolder.appendingPathComponent("\(safeTitle).\(bookFile.format)")

        if !fileManager.fileExists(atPath: destURL.path) {
            try fileManager.copyItem(at: sourceURL, to: destURL)
        }

        let metadataURL = bookFolder.appendingPathComponent("metadata.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let metadataData = try encoder.encode(metadata)
        try metadataData.write(to: metadataURL)

        if let coverPath = metadata.coverImagePath {
            let sourceCover = sourceURL.deletingLastPathComponent().appendingPathComponent(coverPath)
            let destCover = bookFolder.appendingPathComponent("cover.\((coverPath as NSString).pathExtension)")
            if fileManager.fileExists(atPath: sourceCover.path) && !fileManager.fileExists(atPath: destCover.path) {
                try? fileManager.copyItem(at: sourceCover, to: destCover)
            }
        }

        return LocalBookFile(
            id: bookFile.id,
            fileName: destURL.lastPathComponent,
            filePath: destURL.path,
            fileSize: bookFile.fileSize,
            format: bookFile.format,
            fileHash: bookFile.fileHash,
            metadata: metadata,
            sidecarPath: metadataURL.path,
            extractedAt: Date()
        )
    }

    private nonisolated func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespaces)
    }

}

enum LocalLibraryError: LocalizedError {
    case folderNotFound
    case invalidFileFormat
    case metadataExtractionFailed
    case sidecarSaveFailed
    case fileHashCalculationFailed

    var errorDescription: String? {
        switch self {
        case .folderNotFound:
            return "The selected folder could not be found"
        case .invalidFileFormat:
            return "The file format is not supported"
        case .metadataExtractionFailed:
            return "Could not extract metadata from file"
        case .sidecarSaveFailed:
            return "Could not save metadata sidecar file"
        case .fileHashCalculationFailed:
            return "Could not calculate file hash"
        }
    }
}
