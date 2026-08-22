import Foundation
import Logging

final class LocalStorageManager {
    static let shared = LocalStorageManager()

    nonisolated var audiobooksDirectory: URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupportURL.appendingPathComponent("Enve/Audiobooks", isDirectory: true)
    }

    nonisolated private var legacyDocumentsAudiobooksDirectory: URL? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documentsURL.appendingPathComponent("Enve/Audiobooks", isDirectory: true)
    }

    private var metadataDirectory: URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupportURL.appendingPathComponent("Enve/Metadata", isDirectory: true)
    }

    private var playbackStateDirectory: URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupportURL.appendingPathComponent("Enve/PlaybackState", isDirectory: true)
    }

    nonisolated(unsafe) private let fileManager = FileManager.default
    private let operationQueue = DispatchQueue(label: "com.enve.LocalStorageManager", attributes: .concurrent)

    nonisolated(unsafe) private var needsReVerification: Set<String> = []
    private let reVerificationQueue = DispatchQueue(label: "com.enve.reVerification", attributes: .concurrent)

    private init() {
        createDirectoriesIfNeeded()
        let center = NotificationCenter.default
        center.addObserver(
            forName: UnifiedDownloadService.downloadCompletedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.invalidateDownloadedIdsCache() }
        center.addObserver(
            forName: UnifiedDownloadService.downloadFailedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in self?.invalidateDownloadedIdsCache() }
    }

    nonisolated private func candidateAudiobooksDirectories() -> [URL] {
        var dirs: [URL] = [audiobooksDirectory]
        if let legacy = legacyDocumentsAudiobooksDirectory {
            dirs.append(legacy)
        }
        return dirs
    }

    private func createDirectoriesIfNeeded() {
        let directories = [audiobooksDirectory, metadataDirectory, playbackStateDirectory]

        for directory in directories {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
                AppLogger.network.info("Storage directory ready: \(directory.lastPathComponent)")
            } catch {
                AppLogger.network.error(
                    "Failed to create storage directory pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: directory.standardizedFileURL.path)): \(error)"
                )
            }
        }
    }

    nonisolated static func sanitizedId(for bookId: String) -> String {
        return
            bookId
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "?", with: "-")
            .replacingOccurrences(of: "&", with: "-")
            .replacingOccurrences(of: "=", with: "-")
    }

    nonisolated func bookAudioDirectory(for bookId: String) -> URL {
        bookAudioDirectory(for: bookId, in: audiobooksDirectory)
    }

    nonisolated private func bookAudioDirectory(for bookId: String, in audiobooksRoot: URL) -> URL {
        audiobooksRoot.appendingPathComponent(LocalStorageManager.sanitizedId(for: bookId), isDirectory: true)
    }

    private func candidateBookIds(for book: Book) -> [String] {
        var ids: [String] = []

        func appendUnique(_ value: String?) {
            guard let value, !value.isEmpty else { return }
            if !ids.contains(value) { ids.append(value) }
        }

        appendUnique(book.downloadKey)
        appendUnique(book.stableId)
        appendUnique(book.id)
        appendUnique(book.ratingKey)

        switch book.source {
        case .plex:
            appendUnique("plex:\(book.id)")
            appendUnique("plex:\(book.ratingKey)")
        case .audiobookshelf, .webdav, .jellyfin, .emby, .booklore, .realdebrid, .komga, .kavita, .opds, .storyteller, .bookOrbit, .silo,
            .torbox:
            appendUnique("\(book.source.rawValue):\(book.backendId ?? "unknown"):\(book.id)")
            appendUnique("\(book.source.rawValue):\(book.providerId.uuidString):\(book.id)")
        case .local:
            appendUnique("local:unknown:\(book.id)")
            appendUnique("local:\(book.backendId ?? "unknown"):\(book.id)")
        case .smb:
            appendUnique("smb:unknown:\(book.id)")
            appendUnique("smb:\(book.backendId ?? "unknown"):\(book.id)")
        }

        return ids
    }

    func ownedCandidateBookIds(for book: Book) -> [String] {
        if book.libraryId == "rescued-downloads" {
            var ids = [book.downloadKey]
            if book.stableId != book.downloadKey { ids.append(book.stableId) }
            if let partKey = book.partKey, !partKey.isEmpty, !ids.contains(partKey) {
                ids.append(partKey)
            }
            return ids
        }

        let rawLegacyIds = Set([book.id, book.ratingKey].filter { !$0.isEmpty })

        return candidateBookIds(for: book).filter { candidateId in
            guard rawLegacyIds.contains(candidateId),
                candidateId != book.downloadKey,
                candidateId != book.stableId
            else {
                return true
            }

            guard let metadata = try? loadMetadataOverride(OfflineBookMetadata.self, for: candidateId) else {
                return false
            }
            return metadata.stableId == book.stableId
        }
    }

    nonisolated func bookAudioPath(for bookId: String, chapterIndex: Int) -> URL {
        let directory = bookAudioDirectory(for: bookId)
        return directory.appendingPathComponent("chapter_\(chapterIndex).m4b", isDirectory: false)
    }

    func isAudiobookDownloaded(_ bookId: String) -> Bool {

        if UnifiedDownloadService.shared.hasActiveTaskForBookId(bookId) {
            return false
        }

        let extensions = Set(AudiobookFormat.allExtensions + ["dat"])

        let minimumFileSize: Int64 = 102400

        for audiobooksRoot in candidateAudiobooksDirectories() {
            let bookDir = bookAudioDirectory(for: bookId, in: audiobooksRoot)
            var isDir: ObjCBool = false
            let bookDirPath = bookDir.path
            guard fileManager.fileExists(atPath: bookDirPath, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            for ext in extensions {
                let url = bookDir.appendingPathComponent("chapter_0.\(ext)")
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                    if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                        let size = attrs[.size] as? Int64, size >= minimumFileSize
                    {
                        return true
                    }
                }
            }

            let urls =
                (try? fileManager.contentsOfDirectory(at: bookDir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])) ?? []
            if urls.contains(where: { url in
                guard extensions.contains(url.pathExtension.lowercased()) else { return false }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDir = values?.isDirectory ?? false
                let size = Int64(values?.fileSize ?? 0)
                return !isDir && size >= minimumFileSize
            }) {
                return true
            }
        }

        return false
    }

    func deleteDownloadedAudiobook(_ bookId: String) throws {
        var deletedAny = false
        var lastError: Error?

        for audiobooksRoot in candidateAudiobooksDirectories() {
            let bookDir = bookAudioDirectory(for: bookId, in: audiobooksRoot)

            if fileManager.fileExists(atPath: bookDir.path) {
                do {
                    try fileManager.removeItem(at: bookDir)
                    deletedAny = true
                    AppLogger.network.info(
                        "Deleted audiobook directory pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookDir.standardizedFileURL.path))"
                    )
                } catch {
                    lastError = error
                    AppLogger.network.error(
                        "Failed to delete audiobook directory pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: bookDir.standardizedFileURL.path)): \(error.localizedDescription)"
                    )
                }
            }
        }

        if deletedAny { invalidateDownloadedIdsCache() }

        if !deletedAny, let error = lastError {
            throw error
        }
    }

    func localAudiobookFilesIfExists(bookId: String) -> [URL]? {
        let extensions = Set(AudiobookFormat.allExtensions + ["dat"])
        let minimumFileSize: Int64 = 102400

        for audiobooksRoot in candidateAudiobooksDirectories() {
            let bookDir = bookAudioDirectory(for: bookId, in: audiobooksRoot)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: bookDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let allURLs =
                (try? fileManager.contentsOfDirectory(
                    at: bookDir,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]
                )) ?? []

            let audioFiles = allURLs.filter { url in
                guard extensions.contains(url.pathExtension.lowercased()) else { return false }
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let isDirectory = values?.isDirectory ?? false
                let size = Int64(values?.fileSize ?? 0)
                return !isDirectory && size >= minimumFileSize
            }

            guard !audioFiles.isEmpty else { continue }

            let chapterFiles = audioFiles.filter {
                $0.deletingPathExtension().lastPathComponent.hasPrefix("chapter_")
            }.sorted { a, b in
                let aName = a.deletingPathExtension().lastPathComponent
                let bName = b.deletingPathExtension().lastPathComponent
                let aIdx = Int(aName.dropFirst("chapter_".count)) ?? 0
                let bIdx = Int(bName.dropFirst("chapter_".count)) ?? 0
                return aIdx < bIdx
            }

            if !chapterFiles.isEmpty {
                return chapterFiles
            }

            return audioFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        return nil
    }

    func localAudiobookFilesIfExists(for book: Book) -> [URL]? {
        for id in ownedCandidateBookIds(for: book) {
            if let files = localAudiobookFilesIfExists(bookId: id), !files.isEmpty {
                return files
            }
        }
        return nil
    }

    func unsupportedLocalPlaybackReason(for book: Book) -> String? {
        guard let files = localAudiobookFilesIfExists(for: book), !files.isEmpty else {
            return nil
        }

        for fileURL in files {
            if let reason = unsupportedLocalPlaybackReason(forFileAt: fileURL) {
                return reason
            }
        }

        return nil
    }

    nonisolated private func unsupportedLocalPlaybackReason(forFileAt fileURL: URL) -> String? {
        let lowercasedExtension = fileURL.pathExtension.lowercased()
        if ["mkv", "mka", "webm"].contains(lowercasedExtension) {
            return "The download uses a Matroska/WebM container, which iOS cannot play locally."
        }

        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            return nil
        }
        defer { try? handle.close() }

        let header = (try? handle.read(upToCount: 64)) ?? Data()
        guard header.count >= 4 else { return nil }

        if header[0] == 0x1A,
            header[1] == 0x45,
            header[2] == 0xDF,
            header[3] == 0xA3
        {
            return "The download uses a Matroska/WebM container, which iOS cannot play locally."
        }

        return nil
    }

    func isAudiobookDownloaded(_ book: Book) -> Bool {
        for id in ownedCandidateBookIds(for: book) {
            if isAudiobookDownloaded(id) {
                return true
            }
        }
        return false
    }

    func isAudiobookDownloaded(_ book: Book, downloadedIds: Set<String>) -> Bool {
        ownedCandidateBookIds(for: book).contains { downloadedIds.contains(Self.sanitizedId(for: $0)) }
    }

    @discardableResult
    func deleteAudiobook(_ book: Book) -> Bool {
        let ids = ownedCandidateBookIds(for: book)
        var removedAny = false

        for id in ids {
            if deleteAudiobook(id) {
                removedAny = true
            }
        }

        if !removedAny {
            AppLogger.network.warning(
                "No local audiobook data found bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)) candidates=\(ids.count)"
            )
        }
        return removedAny
    }

    func localAudiobookFileURLIfExists(bookId: String) -> URL? {

        let extensions = Set(AudiobookFormat.allExtensions + ["dat"])

        for audiobooksRoot in candidateAudiobooksDirectories() {
            let bookDir = bookAudioDirectory(for: bookId, in: audiobooksRoot)
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: bookDir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            for ext in extensions {
                let url = bookDir.appendingPathComponent("chapter_0.\(ext)")
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                    return url
                }
            }

            let urls = (try? fileManager.contentsOfDirectory(at: bookDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            if let match = urls.first(where: { url in
                guard extensions.contains(url.pathExtension.lowercased()) else { return false }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return !isDir
            }) {
                return match
            }
        }

        return nil
    }

    nonisolated func sizeOfAudiobook(_ bookId: String) -> Int64 {
        var totalSize: Int64 = 0

        for audiobooksRoot in candidateAudiobooksDirectories() {
            let bookDir = bookAudioDirectory(for: bookId, in: audiobooksRoot)
            guard let enumerator = fileManager.enumerator(atPath: bookDir.path) else { continue }

            for case let file as String in enumerator {
                let filePath = bookDir.appendingPathComponent(file)
                if let attributes = try? fileManager.attributesOfItem(atPath: filePath.path),
                    let size = attributes[.size] as? Int64
                {
                    totalSize += size
                }
            }
        }

        return totalSize
    }

    @discardableResult
    func deleteAudiobook(_ bookId: String) -> Bool {
        var removedAny = false
        var lastError: Error?

        for audiobooksRoot in candidateAudiobooksDirectories() {
            let bookDir = bookAudioDirectory(for: bookId, in: audiobooksRoot)
            guard fileManager.fileExists(atPath: bookDir.path) else { continue }
            do {
                try fileManager.removeItem(at: bookDir)
                removedAny = true
            } catch {
                lastError = error
            }
        }

        if removedAny {
            AppLogger.network.info("Deleted audiobook: \(bookId)")
            invalidateDownloadedIdsCache()
            return true
        }

        if let lastError {
            AppLogger.network.error("Failed to delete audiobook \(bookId): \(lastError)")
        }
        return false
    }

    nonisolated func downloadedAudiobookIds() -> [String] {
        Self.downloadedIdsCacheLock.lock()
        if let cached = Self.cachedDownloadedIds {
            Self.downloadedIdsCacheLock.unlock()
            return cached
        }
        Self.downloadedIdsCacheLock.unlock()

        var ids: [String] = []

        for audiobooksRoot in candidateAudiobooksDirectories() {
            do {
                let items = try fileManager.contentsOfDirectory(at: audiobooksRoot, includingPropertiesForKeys: nil)
                let rootIds =
                    items
                    .filter { url in
                        var isDir: ObjCBool = false
                        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                    }
                    .map { $0.lastPathComponent }

                ids.append(contentsOf: rootIds)
            } catch {
                continue
            }
        }

        let result = Array(Set(ids)).sorted()
        Self.downloadedIdsCacheLock.lock()
        Self.cachedDownloadedIds = result
        Self.downloadedIdsCacheLock.unlock()
        return result
    }

    nonisolated func invalidateDownloadedIdsCache() {
        Self.downloadedIdsCacheLock.lock()
        Self.cachedDownloadedIds = nil
        Self.downloadedIdsCacheLock.unlock()
    }

    nonisolated(unsafe) private static var cachedDownloadedIds: [String]?
    nonisolated private static let downloadedIdsCacheLock = NSLock()

    nonisolated func getOldestDownloadedBookIds() -> [(bookId: String, date: Date)] {
        var result: [(String, Date)] = []

        for audiobooksRoot in candidateAudiobooksDirectories() {
            guard
                let items = try? fileManager.contentsOfDirectory(
                    at: audiobooksRoot,
                    includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey]
                )
            else {
                continue
            }

            for item in items {
                if let values = try? item.resourceValues(forKeys: [.isDirectoryKey]),
                    values.isDirectory == true
                {
                    if let values = try? item.resourceValues(forKeys: [.creationDateKey]),
                        let date = values.creationDate
                    {
                        result.append((item.lastPathComponent, date))
                    }
                }
            }
        }

        return result.sorted { $0.1 < $1.1 }
    }

    nonisolated func totalAudiobooksSize() -> Int64 {
        return downloadedAudiobookIds().reduce(0) { total, bookId in
            total + sizeOfAudiobook(bookId)
        }
    }

    func metadataOverridePath(for bookId: String) -> URL {
        let safeId = LocalStorageManager.sanitizedId(for: bookId)
        return metadataDirectory.appendingPathComponent("\(safeId)_metadata.json", isDirectory: false)
    }

    func saveMetadataOverride<T: Encodable>(_ metadata: T, for bookId: String) throws {
        let path = metadataOverridePath(for: bookId)
        let encoded = try JSONEncoder().encode(metadata)
        try encoded.write(to: path, options: .atomic)
    }

    func loadMetadataOverride<T: Decodable>(_ type: T.Type, for bookId: String) throws -> T {
        let path = metadataOverridePath(for: bookId)
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(type, from: data)
    }

    func deleteMetadataOverride(for bookId: String) throws {
        let path = metadataOverridePath(for: bookId)
        try fileManager.removeItem(at: path)
    }

    func playbackStatePath(for bookId: String) -> URL {
        return playbackStateDirectory.appendingPathComponent("\(bookId)_playback.json", isDirectory: false)
    }

    func savePlaybackState<T: Encodable>(_ state: T, for bookId: String) throws {
        let path = playbackStatePath(for: bookId)
        let encoded = try JSONEncoder().encode(state)
        try encoded.write(to: path, options: .atomic)
    }

    func loadPlaybackState<T: Decodable>(_ type: T.Type, for bookId: String) throws -> T {
        let path = playbackStatePath(for: bookId)
        let data = try Data(contentsOf: path)
        return try JSONDecoder().decode(type, from: data)
    }

    func deletePlaybackState(for bookId: String) throws {
        let path = playbackStatePath(for: bookId)
        try fileManager.removeItem(at: path)
    }

    func performCleanup() {
        operationQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }

            let downloadedIds = self.downloadedAudiobookIds()
            AppLogger.network.info(
                "Local storage: \(downloadedIds.count) audiobooks, \(self.formatBytes(self.totalAudiobooksSize())) total"
            )
        }
    }

    nonisolated private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    func availableDiskSpace() -> Int64 {
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: NSHomeDirectory()) else {
            return 0
        }
        return attributes[.systemFreeSize] as? Int64 ?? 0
    }

    func markNeedsReVerification(bookId: String) {
        reVerificationQueue.async(flags: .barrier) {
            self.needsReVerification.insert(bookId)
        }
    }

    func needsReVerification(bookId: String) -> Bool {
        return reVerificationQueue.sync {
            return needsReVerification.contains(bookId)
        }
    }

    func clearReVerification(bookId: String) {
        reVerificationQueue.async(flags: .barrier) {
            self.needsReVerification.remove(bookId)
        }
    }

    func reVerifyAndRedownloadIfNeeded(bookId: String) async -> Bool {
        if let localURL = localAudiobookFileURLIfExists(bookId: bookId) {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: localURL.path) {
                AppLogger.network.info(
                    "Deleting corrupted file \(DiagnosticLogSanitizer.fileDescriptor(for: localURL))"
                )
                try? fileManager.removeItem(at: localURL)

                let bookDir = localURL.deletingLastPathComponent()
                if let contents = try? fileManager.contentsOfDirectory(at: bookDir, includingPropertiesForKeys: nil),
                    contents.isEmpty
                {
                    try? fileManager.removeItem(at: bookDir)
                }
            }
        }

        clearReVerification(bookId: bookId)
        return true
    }

    @discardableResult
    func reassociateDownload(from oldKey: String, to newKey: String) -> Bool {
        let oldSanitized = LocalStorageManager.sanitizedId(for: oldKey)
        let newSanitized = LocalStorageManager.sanitizedId(for: newKey)
        guard oldSanitized != newSanitized else { return true }

        let fm = FileManager.default
        var movedAudio = false

        for audiobooksRoot in candidateAudiobooksDirectories() {
            let oldDir = audiobooksRoot.appendingPathComponent(oldSanitized, isDirectory: true)
            let newDir = audiobooksRoot.appendingPathComponent(newSanitized, isDirectory: true)
            if fm.fileExists(atPath: oldDir.path) {
                if fm.fileExists(atPath: newDir.path) {
                    try? fm.removeItem(at: newDir)
                }
                do {
                    try fm.moveItem(at: oldDir, to: newDir)
                    movedAudio = true
                    AppLogger.network.info("Moved audio: \(oldSanitized) -> \(newSanitized)")
                } catch {
                    AppLogger.network.error("Failed to move audio dir: \(error)")
                }
                break
            }
        }

        guard movedAudio else { return false }

        let oldMeta = metadataOverridePath(for: oldKey)
        let newMeta = metadataOverridePath(for: newKey)
        if fm.fileExists(atPath: oldMeta.path) {
            try? fm.removeItem(at: newMeta)
            try? fm.moveItem(at: oldMeta, to: newMeta)
            AppLogger.network.info("Moved metadata: \(oldSanitized) -> \(newSanitized)")
        }

        let oldCover = coverOverridePath(for: oldKey)
        let newCover = coverOverridePath(for: newKey)
        if fm.fileExists(atPath: oldCover.path) {
            try? fm.removeItem(at: newCover)
            try? fm.moveItem(at: oldCover, to: newCover)
            AppLogger.network.info("Moved cover: \(oldSanitized) -> \(newSanitized)")
        }

        let oldPlayback = playbackStatePath(for: oldKey)
        let newPlayback = playbackStatePath(for: newKey)
        if fm.fileExists(atPath: oldPlayback.path) {
            try? fm.removeItem(at: newPlayback)
            try? fm.moveItem(at: oldPlayback, to: newPlayback)
            AppLogger.network.info("Moved playback state: \(oldSanitized) -> \(newSanitized)")
        }

        return true
    }

    nonisolated func coverOverridePath(for bookId: String) -> URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let coversDir = appSupportURL.appendingPathComponent("Enve/Covers", isDirectory: true)
        let fileName = "\(LocalStorageManager.sanitizedId(for: bookId)).jpg"
        return coversDir.appendingPathComponent(fileName, isDirectory: false)
    }

    @discardableResult
    func saveCoverOverride(for bookId: String, imageData: Data) throws -> URL {
        let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let coversDir = appSupportURL.appendingPathComponent("Enve/Covers", isDirectory: true)
        try FileManager.default.createDirectory(at: coversDir, withIntermediateDirectories: true)
        let url = coverOverridePath(for: bookId)
        try imageData.write(to: url, options: .atomic)
        AppLogger.network.info("Saved cover override \(DiagnosticLogSanitizer.fileDescriptor(for: url))")
        return url
    }

    func saveCoverOverride(from remoteURL: URL, for bookId: String) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: remoteURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try saveCoverOverride(for: bookId, imageData: data)
    }
}
