import AVFoundation
import CryptoKit
import Foundation
import Logging

enum SMBScanMode: String, CaseIterable, Identifiable {
    case quick = "quick"
    case full = "full"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quick: return "Quick Scan"
        case .full: return "Full Scan"
        }
    }

    var description: String {
        switch self {
        case .quick: return "Fast scan using file sizes to estimate duration"
        case .full: return "Downloads files to extract exact duration and embedded metadata"
        }
    }
}

actor SMBLibraryService {
    static let shared = SMBLibraryService()

    private let userDefaultsKey = "smb_library_sources"
    private let passwordKeychainPrefix = "smb_library_"

    private init() {}

    func getSources() -> [SMBLibrarySource] {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
            let sources = try? JSONDecoder().decode([SMBLibrarySource].self, from: data)
        else {
            return []
        }
        return sources
    }

    func saveSource(_ source: SMBLibrarySource, password: String) {
        var sources = getSources()

        sources.removeAll { $0.id == source.id }
        sources.append(source)

        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }

        savePassword(password, for: source.id)
    }

    func deleteSource(id: String) {
        var sources = getSources()
        sources.removeAll { $0.id == id }

        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }

        deletePassword(for: id)
    }

    func updateLastScanned(id: String) {
        var sources = getSources()
        if let index = sources.firstIndex(where: { $0.id == id }) {
            var source = sources[index]
            source = SMBLibrarySource(
                id: source.id,
                name: source.name,
                hostname: source.hostname,
                port: source.port,
                shareName: source.shareName,
                username: source.username,
                folderPath: source.folderPath,
                createdAt: source.createdAt,
                lastScanned: Date(),
                isEnabled: source.isEnabled
            )
            sources[index] = source

            if let data = try? JSONEncoder().encode(sources) {
                UserDefaults.standard.set(data, forKey: userDefaultsKey)
            }
        }
    }

    private func savePassword(_ password: String, for sourceId: String) {
        let key = passwordKeychainPrefix + sourceId
        let data = password.data(using: .utf8)!

        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    func getPassword(for sourceId: String) -> String? {
        let key = passwordKeychainPrefix + sourceId

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let password = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return password
    }

    private func deletePassword(for sourceId: String) {
        let key = passwordKeychainPrefix + sourceId

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private let booksStorageKey = "smb_indexed_books"

    func getBooks(for sourceId: String) -> [SMBBook] {
        let allBooks = getAllBooks()
        return allBooks.filter { $0.sourceId == sourceId }
    }

    func getAllBooks() -> [SMBBook] {
        guard let data = UserDefaults.standard.data(forKey: booksStorageKey),
            let books = try? JSONDecoder().decode([SMBBook].self, from: data)
        else {
            return []
        }
        return books
    }

    private func saveBooks(_ books: [SMBBook]) {
        if let data = try? JSONEncoder().encode(books) {
            UserDefaults.standard.set(data, forKey: booksStorageKey)
        }
    }

    private func upsertBook(_ book: SMBBook) {
        var books = getAllBooks()
        if let index = books.firstIndex(where: { $0.id == book.id }) {
            books[index] = book
        } else {
            books.append(book)
        }
        saveBooks(books)
    }

    func deleteBooks(for sourceId: String) {
        var books = getAllBooks()
        books.removeAll { $0.sourceId == sourceId }
        saveBooks(books)
    }

    func extractChaptersFromFile(smbService: SMBService, filePath: String) async throws -> [Chapter] {
        let fileSize = try await smbService.getFileSize(at: filePath)
        let fileName = (filePath as NSString).lastPathComponent

        let fileEntry = SMBService.FileEntry(
            name: fileName,
            path: filePath,
            isDirectory: false,
            size: fileSize,
            modified: nil,
            created: nil
        )

        let result = await extractAudioMetadata(smbService: smbService, audioFile: fileEntry)

        guard let smbChapters = result.metadata?.chapters, !smbChapters.isEmpty else {
            return []
        }

        return await MainActor.run {
            smbChapters.enumerated().map { index, smbChapter in
                Chapter(
                    id: "smb_chapter_\(index + 1)",
                    start: smbChapter.startTime,
                    end: smbChapter.endTime ?? smbChapter.startTime,
                    title: smbChapter.title
                )
            }
        }
    }

    func scanLibrary(
        _ source: SMBLibrarySource,
        mode: SMBScanMode = .quick,
        progressCallback: ((String) -> Void)? = nil
    ) async throws -> SMBLibraryScanResult {
        guard let password = getPassword(for: source.id) else {
            throw SMBService.SMBError.authenticationFailed
        }

        let startTime = Date()
        let smbService = SMBService()
        let config = source.toServerConfiguration()

        progressCallback?(mode == .full ? "Connecting (Full Scan)..." : "Connecting (Quick Scan)...")

        try await smbService.connect(config: config, password: password)
        defer {
            Task { await smbService.disconnect() }
        }

        progressCallback?("Scanning folders...")

        let existingCount = getBooks(for: source.id).count
        deleteBooks(for: source.id)
        AppLogger.network.info("[SMB Scan] Cleared \(existingCount) existing books for source \(source.id)")

        var discoveredBooks: [SMBBook] = []
        var errors: [String] = []
        let forcedStandalonePaths = await MainActor.run {
            AudiobookGroupingOverrideStore.shared.forcedStandalonePaths(source: .smb, sourceId: source.id)
        }

        await scanFolderRecursively(
            smbService: smbService,
            path: source.folderPath,
            sourceId: source.id,
            scanMode: mode,
            discoveredBooks: &discoveredBooks,
            errors: &errors,
            progressCallback: progressCallback,
            forcedStandalonePaths: forcedStandalonePaths
        )

        progressCallback?("Found \(discoveredBooks.count) audiobooks, saving...")

        for book in discoveredBooks {
            upsertBook(book)
        }

        AppLogger.network.info("[SMB Scan] Saved \(discoveredBooks.count) books")

        updateLastScanned(id: source.id)

        let duration = Date().timeIntervalSince(startTime)

        progressCallback?("Scan complete!")

        return SMBLibraryScanResult(
            booksFound: discoveredBooks.count,
            booksAdded: discoveredBooks.count,
            booksUpdated: 0,
            errors: errors,
            scanDuration: duration
        )
    }

    private func scanFolderRecursively(
        smbService: SMBService,
        path: String,
        sourceId: String,
        scanMode: SMBScanMode,
        discoveredBooks: inout [SMBBook],
        errors: inout [String],
        progressCallback: ((String) -> Void)?,
        forcedStandalonePaths: Set<String>,
        depth: Int = 0
    ) async {
        guard depth < 10 else { return }

        do {
            let entries = try await smbService.listDirectory(at: path)

            let files = entries.filter { !$0.isDirectory }
            let folders = entries.filter { $0.isDirectory }

            let audioFiles = files.filter { isAudioFile($0.name) }
            let metadataFile = files.first { isMetadataFile($0.name) }
            let coverFile = files.first { isCoverImage($0.name) }

            if !audioFiles.isEmpty {
                let scanTypeLabel = scanMode == .full ? "Full scan" : "Quick scan"
                progressCallback?("\(scanTypeLabel): \((path as NSString).lastPathComponent)")

                AppLogger.network.info("[SMB Scan] Folder: \(path) (mode: \(scanMode.rawValue))")
                AppLogger.network.info("[SMB Scan] Audio files found: \(audioFiles.map { $0.name })")

                let audioGroups = splitAudioGroups(
                    audioFiles,
                    forcedStandalonePaths: forcedStandalonePaths
                )
                let isCollectionFolder = audioGroups.count > 1
                if audioGroups.count > 1 {
                    AppLogger.network.info("[SMB Scan] Split folder into \(audioGroups.count) book groups using format-aware heuristic")
                }

                var metadata: SMBBookMetadata?
                if !isCollectionFolder, let metaFile = metadataFile {
                    metadata = await parseMetadataFile(smbService: smbService, path: metaFile.path)
                    AppLogger.network.debug(
                        "[SMB Scan] Parsed metadata fileDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: metaFile.name)) hasTitle=\(metadata?.title != nil)"
                    )
                }

                for audioGroup in audioGroups {
                    let sortedAudioFiles = AudiobookFileGrouping.sorted(audioGroup, name: \.name)

                    var realDuration: TimeInterval? = nil
                    var embeddedMetadata: SMBBookMetadata? = nil

                    if scanMode == .full, let primaryAudio = sortedAudioFiles.first {
                        progressCallback?("Extracting metadata: \((primaryAudio.name as NSString).deletingPathExtension)")
                        let extracted = await extractAudioMetadata(smbService: smbService, audioFile: primaryAudio)
                        realDuration = extracted.duration
                        embeddedMetadata = extracted.metadata

                        if let dur = realDuration {
                            AppLogger.network.info(
                                "[SMB Scan] Extracted real duration: \(Int(dur / 3600))h \(Int(dur.truncatingRemainder(dividingBy: 3600) / 60))m"
                            )
                        }
                        if embeddedMetadata != nil {
                            AppLogger.network.info(
                                "[SMB Scan] Extracted embedded metadata: title=\(embeddedMetadata?.title ?? "nil"), author=\(embeddedMetadata?.author ?? "nil")"
                            )
                        }
                    }

                    let smbAudioFiles = sortedAudioFiles.enumerated().map { index, entry in
                        let fileDuration: TimeInterval?
                        if index == 0, let real = realDuration {
                            fileDuration = real
                        } else {
                            fileDuration = estimateDuration(size: entry.size, filename: entry.name)
                        }
                        return SMBAudioFile(
                            name: entry.name,
                            path: entry.path,
                            size: entry.size,
                            duration: fileDuration,
                            trackNumber: index + 1
                        )
                    }

                    let finalMetadata = mergeMetadata(embedded: embeddedMetadata, sidecar: metadata)
                    let measuredDurations = smbAudioFiles.compactMap(\.duration)
                    let groupDuration = measuredDurations.isEmpty ? nil : measuredDurations.reduce(0, +)

                    let folderName = (path as NSString).lastPathComponent
                    let primaryFilePath = smbAudioFiles.first?.path ?? path
                    let primaryFileName = smbAudioFiles.first?.name ?? ""
                    let primaryFileBase = (primaryFileName as NSString).deletingPathExtension
                    let fallbackTitle = audioGroup.count > 1
                        ? AudiobookFileGrouping.inferredTitle(for: primaryFileName)
                        : primaryFileBase

                    let title: String
                    if let metadataTitle = finalMetadata?.title, !metadataTitle.isEmpty {
                        title = metadataTitle
                    } else if !fallbackTitle.isEmpty {
                        title = cleanTitle(fallbackTitle)
                    } else {
                        title = cleanTitle(folderName)
                    }

                    AppLogger.network.debug(
                        "[SMB Scan] Selected primary fileDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: primaryFileName)) titleDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: title))"
                    )

                    let stableBookId = bookId(sourceId: sourceId, path: isCollectionFolder ? primaryFilePath : path)

                    let oldPrimaryFileId = bookId(sourceId: sourceId, path: primaryFilePath)
                    if !isCollectionFolder, oldPrimaryFileId != stableBookId {
                        migrateProgressIfNeeded(from: oldPrimaryFileId, to: stableBookId, sourceId: sourceId)
                    }

                    var localCoverPath: String? = nil
                    if !isCollectionFolder, let cover = coverFile {
                        localCoverPath = await downloadCoverToCache(
                            smbService: smbService,
                            remotePath: cover.path,
                            bookId: stableBookId
                        )
                    }

                    let book = SMBBook(
                        id: stableBookId,
                        sourceId: sourceId,
                        title: title,
                        author: finalMetadata?.author ?? (isCollectionFolder ? nil : extractAuthor(from: folderName)),
                        narrator: finalMetadata?.narrator,
                        description: finalMetadata?.description,
                        series: finalMetadata?.series ?? (isCollectionFolder ? nil : extractSeries(from: folderName)),
                        seriesNumber: finalMetadata?.seriesNumber ?? (isCollectionFolder ? nil : extractSeriesNumber(from: folderName)),
                        publishedYear: finalMetadata?.publishedYear,
                        genres: finalMetadata?.genres,
                        publisher: finalMetadata?.publisher,
                        isbn: finalMetadata?.isbn,
                        asin: finalMetadata?.asin,
                        duration: finalMetadata?.duration ?? groupDuration,
                        folderPath: isCollectionFolder ? primaryFilePath : path,
                        audioFiles: smbAudioFiles,
                        coverPath: localCoverPath,
                        metadataPath: isCollectionFolder ? nil : metadataFile?.path,
                        chapters: finalMetadata?.chapters,
                        indexedAt: Date(),
                        lastScannedAt: Date()
                    )

                    discoveredBooks.append(book)
                }
            }

            for folder in folders {
                guard !folder.name.hasPrefix(".") else { continue }

                await scanFolderRecursively(
                    smbService: smbService,
                    path: folder.path,
                    sourceId: sourceId,
                    scanMode: scanMode,
                    discoveredBooks: &discoveredBooks,
                    errors: &errors,
                    progressCallback: progressCallback,
                    forcedStandalonePaths: forcedStandalonePaths,
                    depth: depth + 1
                )
            }
        } catch {
            errors.append("Failed to scan \(path): \(error.localizedDescription)")
        }
    }

    private func isAudioFile(_ name: String) -> Bool {
        let audioExtensions = ["mp3", "m4a", "m4b", "mp4", "aac", "flac", "opus", "ogg", "wav", "wma"]
        let ext = (name as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext)
    }

    private func splitAudioGroups(
        _ files: [SMBService.FileEntry],
        forcedStandalonePaths: Set<String>
    ) -> [[SMBService.FileEntry]] {
        guard files.count > 1 else { return [files] }

        return AudiobookFileGrouping.groups(
            files,
            name: \.name,
            bookEvidence: { $0.size >= AudiobookFileGrouping.minimumStandaloneBookSize },
            forcedStandalone: { forcedStandalonePaths.contains($0.path) }
        )
    }

    private func isMetadataFile(_ name: String) -> Bool {
        let metadataFiles = [
            "metadata.json",
            "metadata.opf",
            "audiobook.json",
            "book.json",
            "info.json",
            "desc.txt",
            ".nfo",
        ]
        let lowercaseName = name.lowercased()
        return metadataFiles.contains(lowercaseName) || lowercaseName.hasSuffix(".nfo") || lowercaseName.hasSuffix(".opf")
    }

    private func isCoverImage(_ name: String) -> Bool {
        let coverNames = ["cover", "folder", "front", "album", "poster", "artwork"]
        let imageExtensions = ["jpg", "jpeg", "png", "webp", "gif"]

        let lowercaseName = name.lowercased()
        let ext = (lowercaseName as NSString).pathExtension
        let baseName = (lowercaseName as NSString).deletingPathExtension

        guard imageExtensions.contains(ext) else { return false }
        return coverNames.contains(baseName)
    }

    nonisolated private var coverCacheDirectory: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let smbCoversDir = cacheDir.appendingPathComponent("SMBCovers", isDirectory: true)
        try? FileManager.default.createDirectory(at: smbCoversDir, withIntermediateDirectories: true)
        return smbCoversDir
    }

    func ensureCachedCover(for book: Book) async -> String? {
        guard book.source == .smb, let sourceId = book.backendId else { return nil }

        if let cached = getCachedCoverPath(for: book.id) {
            AppLogger.network.debug(
                "[SMB Cover] Found cached cover id=\(DiagnosticLogSanitizer.identifier(for: cached))"
            )
            return cached
        }

        let smbBooks = getBooks(for: sourceId)
        guard let smbBook = smbBooks.first(where: { $0.id == book.id }) else {
            AppLogger.network.warning(
                "[SMB Cover] Book not found bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
            )
            return nil
        }

        guard let source = getSources().first(where: { $0.id == sourceId }),
            let password = getPassword(for: sourceId)
        else {
            AppLogger.network.warning(
                "[SMB Cover] Missing source credentials sourceDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: sourceId))"
            )
            return nil
        }

        let smbService = SMBService()
        do {
            try await smbService.connect(config: source.toServerConfiguration(), password: password)
            defer { Task { await smbService.disconnect() } }

            let items = try await smbService.listDirectory(at: smbBook.folderPath)
            let files = items.filter { !$0.isDirectory }

            if let coverFile = files.first(where: { isCoverImage($0.name) }) {
                AppLogger.network.debug(
                    "[SMB Cover] Found cover pathDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: coverFile.path))"
                )
                if let cachedPath = await downloadCoverToCache(smbService: smbService, remotePath: coverFile.path, bookId: book.id) {
                    return cachedPath
                }
            } else {
                AppLogger.network.info("[SMB Cover] No cover image found in folder: \(smbBook.folderPath)")
            }
        } catch {
            AppLogger.network.error("[SMB Cover] Failed to cache cover: \(error)")
        }
        return getCachedCoverPath(for: book.id)
    }

    private func downloadCoverToCache(smbService: SMBService, remotePath: String, bookId: String) async -> String? {
        let ext = (remotePath as NSString).pathExtension.lowercased()
        let localFileName = "\(bookId).\(ext.isEmpty ? "jpg" : ext)"
        let localURL = coverCacheDirectory.appendingPathComponent(localFileName)

        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL.path
        }

        do {
            try await smbService.downloadFile(from: remotePath, to: localURL, onProgress: nil)
            AppLogger.network.info("[SMB Scan] Cached cover: \(localFileName)")
            return localURL.path
        } catch {
            AppLogger.network.error("[SMB Scan] Failed to cache cover from \(remotePath): \(error.localizedDescription)")
            return nil
        }
    }

    nonisolated func getCachedCoverPath(for bookId: String) -> String? {
        let extensions = ["jpg", "jpeg", "png", "webp", "gif"]
        for ext in extensions {
            let localURL = coverCacheDirectory.appendingPathComponent("\(bookId).\(ext)")
            if FileManager.default.fileExists(atPath: localURL.path) {
                return localURL.path
            }
        }
        return nil
    }

    private func parseMetadataFile(smbService: SMBService, path: String) async -> SMBBookMetadata? {
        do {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".metadata")
            defer { try? FileManager.default.removeItem(at: tempURL) }

            try await smbService.downloadFile(from: path, to: tempURL, onProgress: nil)
            let data = try Data(contentsOf: tempURL)

            let ext = (path as NSString).pathExtension.lowercased()

            if ext == "json" {
                return parseJSONMetadata(data)
            } else if ext == "opf" {
                return parseOPFMetadata(data)
            } else if ext == "nfo" {
                return parseNFOMetadata(data)
            }
        } catch {
            AppLogger.network.error("Failed to parse metadata at \(path): \(error)")
        }

        return nil
    }

    private func parseJSONMetadata(_ data: Data) -> SMBBookMetadata? {
        do {
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var metadata = SMBBookMetadata()

                metadata.title =
                    json["title"] as? String
                    ?? json["name"] as? String

                metadata.author =
                    json["author"] as? String
                    ?? json["authors"] as? String
                    ?? (json["authors"] as? [String])?.joined(separator: ", ")

                metadata.narrator =
                    json["narrator"] as? String
                    ?? json["narrators"] as? String
                    ?? (json["narrators"] as? [String])?.joined(separator: ", ")
                    ?? json["reader"] as? String

                metadata.description =
                    json["description"] as? String
                    ?? json["summary"] as? String
                    ?? json["synopsis"] as? String

                metadata.series =
                    json["series"] as? String
                    ?? json["seriesName"] as? String

                if let seriesNum = json["seriesNumber"] as? Int {
                    metadata.seriesNumber = seriesNum
                } else if let seriesNum = json["series_index"] as? Int {
                    metadata.seriesNumber = seriesNum
                } else if let seriesNum = json["seriesNumber"] as? String, let num = Int(seriesNum) {
                    metadata.seriesNumber = num
                }

                if let year = json["year"] as? Int {
                    metadata.publishedYear = year
                } else if let year = json["publishedYear"] as? Int {
                    metadata.publishedYear = year
                } else if let yearStr = json["year"] as? String, let year = Int(yearStr) {
                    metadata.publishedYear = year
                }

                metadata.genres =
                    json["genres"] as? [String]
                    ?? json["tags"] as? [String]

                metadata.publisher = json["publisher"] as? String
                metadata.isbn =
                    json["isbn"] as? String
                    ?? json["isbn13"] as? String
                metadata.asin = json["asin"] as? String

                if let duration = json["duration"] as? Double {
                    if duration > 1_000_000 {
                        metadata.duration = duration / 1000.0
                    } else {
                        metadata.duration = duration
                    }
                } else if let durationInt = json["duration"] as? Int {
                    if durationInt > 1_000_000 {
                        metadata.duration = Double(durationInt) / 1000.0
                    } else {
                        metadata.duration = Double(durationInt)
                    }
                } else if let durationStr = json["duration"] as? String {
                    metadata.duration = parseDurationString(durationStr)
                }

                if metadata.duration == nil {
                    if let lengthMs = json["lengthMs"] as? Double {
                        metadata.duration = lengthMs / 1000.0
                    } else if let lengthMs = json["lengthMs"] as? Int {
                        metadata.duration = Double(lengthMs) / 1000.0
                    } else if let length = json["length"] as? Double {
                        metadata.duration = length
                    } else if let length = json["length"] as? Int {
                        metadata.duration = Double(length)
                    }
                }

                AppLogger.network.info("[SMB Scan] Parsed metadata duration: \(metadata.duration ?? 0) seconds")

                return metadata
            }
        } catch {
            AppLogger.network.error("Failed to parse JSON metadata: \(error)")
        }
        return nil
    }

    private func parseOPFMetadata(_ data: Data) -> SMBBookMetadata? {
        guard let xmlString = String(data: data, encoding: .utf8) else { return nil }

        var metadata = SMBBookMetadata()

        metadata.title =
            extractXMLValue(from: xmlString, tag: "dc:title")
            ?? extractXMLValue(from: xmlString, tag: "title")

        metadata.author =
            extractXMLValue(from: xmlString, tag: "dc:creator")
            ?? extractXMLValue(from: xmlString, tag: "creator")

        metadata.description =
            extractXMLValue(from: xmlString, tag: "dc:description")
            ?? extractXMLValue(from: xmlString, tag: "description")

        metadata.publisher = extractXMLValue(from: xmlString, tag: "dc:publisher")

        if let dateStr = extractXMLValue(from: xmlString, tag: "dc:date") {
            if let year = Int(dateStr.prefix(4)) {
                metadata.publishedYear = year
            }
        }

        return metadata
    }

    private func parseNFOMetadata(_ data: Data) -> SMBBookMetadata? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var metadata = SMBBookMetadata()

        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.lowercased().hasPrefix("title:") {
                metadata.title = String(trimmed.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("author:") {
                metadata.author = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("narrator:") || trimmed.lowercased().hasPrefix("reader:") {
                let prefix = trimmed.lowercased().hasPrefix("narrator:") ? 9 : 7
                metadata.narrator = String(trimmed.dropFirst(prefix)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("series:") {
                metadata.series = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.lowercased().hasPrefix("year:") {
                if let year = Int(String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)) {
                    metadata.publishedYear = year
                }
            }
        }

        return metadata
    }

    private func extractXMLValue(from xml: String, tag: String) -> String? {
        let pattern = "<\(tag)[^>]*>([^<]+)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }

        if let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            if let range = Range(match.range(at: 1), in: xml) {
                return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func extractAudioMetadata(
        smbService: SMBService,
        audioFile: SMBService.FileEntry
    ) async -> (duration: TimeInterval?, metadata: SMBBookMetadata?) {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SMBMetadataScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let ext = (audioFile.name as NSString).pathExtension.lowercased()
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString + "." + ext)

        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        do {
            let chunkSize: Int64 = 8 * 1024 * 1024

            if audioFile.size <= chunkSize * 2 {
                AppLogger.network.info(
                    "[SMB Scan] File \(audioFile.name) is small (\(audioFile.size / 1024 / 1024)MB), downloading entirely"
                )
                try await smbService.downloadFilePartial(from: audioFile.path, to: tempFile, maxBytes: audioFile.size, onProgress: nil)
            } else {
                AppLogger.network.info("[SMB Scan] Downloading first \(chunkSize / 1024 / 1024)MB of \(audioFile.name)")
                let firstChunk = try await smbService.readFileRange(from: audioFile.path, offset: 0, length: Int(chunkSize))

                let lastChunkOffset = audioFile.size - chunkSize
                AppLogger.network.info(
                    "[SMB Scan] Downloading last \(chunkSize / 1024 / 1024)MB of \(audioFile.name) (offset: \(lastChunkOffset))"
                )
                let lastChunk = try await smbService.readFileRange(from: audioFile.path, offset: lastChunkOffset, length: Int(chunkSize))

                let fileHandle = try FileHandle(forWritingTo: tempFile)
                defer { try? fileHandle.close() }

                FileManager.default.createFile(atPath: tempFile.path, contents: nil, attributes: nil)
                let writeHandle = try FileHandle(forWritingTo: tempFile)
                defer { try? writeHandle.close() }

                try writeHandle.write(contentsOf: firstChunk)

                try writeHandle.seek(toOffset: UInt64(lastChunkOffset))
                try writeHandle.write(contentsOf: lastChunk)

                AppLogger.network.info("[SMB Scan] Created sparse temp file with first and last chunks")
            }

            let asset = AVURLAsset(url: tempFile)

            var duration: TimeInterval? = nil
            let durationValue = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(durationValue)
            if seconds.isFinite && seconds > 0 {
                duration = seconds
            }

            var metadata = SMBBookMetadata()
            let commonMetadata = try await asset.load(.commonMetadata)

            for item in commonMetadata {
                guard let key = item.commonKey else { continue }

                switch key {
                case .commonKeyTitle:
                    if let value = try? await item.load(.stringValue) {
                        metadata.title = value
                    }
                case .commonKeyArtist, .commonKeyAuthor:
                    if let value = try? await item.load(.stringValue) {
                        metadata.author = value
                    }
                case .commonKeyAlbumName:
                    if let value = try? await item.load(.stringValue) {
                        if metadata.series == nil {
                            metadata.series = value
                        }
                    }
                case .commonKeyDescription:
                    if let value = try? await item.load(.stringValue) {
                        metadata.description = value
                    }
                case .commonKeyPublisher:
                    if let value = try? await item.load(.stringValue) {
                        metadata.publisher = value
                    }
                case .commonKeyCreationDate:
                    if let value = try? await item.load(.stringValue), let year = Int(value.prefix(4)) {
                        metadata.publishedYear = year
                    }
                default:
                    break
                }
            }

            let formats = try await asset.load(.availableMetadataFormats)
            for format in formats {
                let formatMetadata = try await asset.loadMetadata(for: format)
                for item in formatMetadata {
                    if let key = item.key as? String {
                        if key.lowercased().contains("narrator") || key.lowercased().contains("nrt") {
                            if let value = try? await item.load(.stringValue) {
                                metadata.narrator = value
                            }
                        }
                        if key.lowercased().contains("genre") || key.lowercased().contains("gnre") {
                            if let value = try? await item.load(.stringValue) {
                                metadata.genres = [value]
                            }
                        }
                    }
                }
            }

            do {
                let chapterLocales = try await asset.load(.availableChapterLocales)
                if let preferredLocale = chapterLocales.first {
                    let chapterGroups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: [
                        preferredLocale.identifier
                    ])
                    var chapters: [SMBChapter] = []
                    for group in chapterGroups {
                        let startTime = CMTimeGetSeconds(group.timeRange.start)
                        let endTime = CMTimeGetSeconds(group.timeRange.end)
                        var title = "Chapter \(chapters.count + 1)"
                        for item in group.items {
                            if item.commonKey == .commonKeyTitle,
                                let value = try? await item.load(.stringValue)
                            {
                                title = value
                            }
                        }
                        chapters.append(SMBChapter(title: title, startTime: startTime, endTime: endTime))
                    }
                    if !chapters.isEmpty {
                        metadata.chapters = chapters
                        AppLogger.network.info("[SMB Scan] Extracted \(chapters.count) chapters from audio file")
                    }
                }
            } catch {
                AppLogger.network.error("[SMB Scan] No chapters found in audio file: \(error.localizedDescription)")
            }

            return (duration, metadata.title != nil || metadata.author != nil || metadata.chapters != nil ? metadata : nil)

        } catch {
            AppLogger.network.error("[SMB Scan] Failed to extract metadata for \(audioFile.name): \(error.localizedDescription)")
            return (nil, nil)
        }
    }

    private func mergeMetadata(embedded: SMBBookMetadata?, sidecar: SMBBookMetadata?) -> SMBBookMetadata? {
        guard embedded != nil || sidecar != nil else { return nil }

        var merged = SMBBookMetadata()

        merged.title = embedded?.title ?? sidecar?.title
        merged.author = embedded?.author ?? sidecar?.author
        merged.narrator = embedded?.narrator ?? sidecar?.narrator
        merged.description = embedded?.description ?? sidecar?.description
        merged.series = embedded?.series ?? sidecar?.series
        merged.seriesNumber = embedded?.seriesNumber ?? sidecar?.seriesNumber
        merged.publishedYear = embedded?.publishedYear ?? sidecar?.publishedYear
        merged.genres = embedded?.genres ?? sidecar?.genres
        merged.publisher = embedded?.publisher ?? sidecar?.publisher
        merged.isbn = embedded?.isbn ?? sidecar?.isbn
        merged.asin = embedded?.asin ?? sidecar?.asin
        merged.duration = embedded?.duration ?? sidecar?.duration
        merged.chapters = embedded?.chapters ?? sidecar?.chapters

        return merged
    }

    private func extractAudioDuration(smbService: SMBService, audioFile: SMBService.FileEntry) async -> TimeInterval? {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SMBDurationScan", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let ext = (audioFile.name as NSString).pathExtension
        let tempFile = tempDir.appendingPathComponent(UUID().uuidString + "." + ext)

        defer {
            try? FileManager.default.removeItem(at: tempFile)
        }

        do {
            try await smbService.downloadFile(from: audioFile.path, to: tempFile, onProgress: nil)

            let asset = AVURLAsset(url: tempFile)
            let duration = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(duration)

            if seconds.isFinite && seconds > 0 {
                return seconds
            }
        } catch {
            AppLogger.network.error("[SMB Scan] Failed to extract duration for \(audioFile.name): \(error.localizedDescription)")
        }

        return nil
    }

    private func estimateDuration(size: Int64, filename: String) -> TimeInterval? {
        let ext = (filename as NSString).pathExtension.lowercased()
        let bitrateKbps: Double

        switch ext {
        case "mp3": bitrateKbps = 64
        case "m4a", "m4b", "aac": bitrateKbps = 64
        case "flac": bitrateKbps = 800
        case "ogg", "opus": bitrateKbps = 64
        default: bitrateKbps = 64
        }

        let bytesPerSecond = bitrateKbps * 1000 / 8
        return Double(size) / bytesPerSecond
    }

    private func cleanTitle(_ folderName: String) -> String {
        var title = folderName

        title = title.replacingOccurrences(of: "\\s*[\\(\\[]\\d{4}[\\)\\]]\\s*", with: "", options: .regularExpression)

        title = title.replacingOccurrences(
            of: "\\s*[\\(\\[]\\d+\\s*kbps[\\)\\]]\\s*",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        title = title.replacingOccurrences(of: "\\s*-?\\s*Audiobook\\s*$", with: "", options: [.regularExpression, .caseInsensitive])

        return title.trimmingCharacters(in: .whitespaces)
    }

    private func extractAuthor(from folderName: String) -> String? {
        let separators = [" - ", " \u{2013} ", " \u{2014} ", "_-_"]
        for sep in separators {
            let parts = folderName.components(separatedBy: sep)
            if parts.count >= 2 {
                return parts[0].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func extractSeries(from folderName: String) -> String? {
        let patterns = [
            "(.+?)\\s+Book\\s+\\d+",
            "(.+?)\\s+#\\d+",
            "(.+?)\\s+Vol\\.?\\s*\\d+",
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                let match = regex.firstMatch(in: folderName, range: NSRange(folderName.startIndex..., in: folderName)),
                let range = Range(match.range(at: 1), in: folderName)
            {
                return String(folderName[range]).trimmingCharacters(in: .whitespaces)
            }
        }

        return nil
    }

    private func extractSeriesNumber(from folderName: String) -> Int? {
        let patterns = [
            "Book\\s+(\\d+)",
            "#(\\d+)",
            "Vol\\.?\\s*(\\d+)",
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                let match = regex.firstMatch(in: folderName, range: NSRange(folderName.startIndex..., in: folderName)),
                let range = Range(match.range(at: 1), in: folderName)
            {
                return Int(folderName[range])
            }
        }

        return nil
    }

    private func parseDurationString(_ str: String) -> TimeInterval? {
        let parts = str.components(separatedBy: ":")
        if parts.count == 3,
            let hours = Double(parts[0]),
            let minutes = Double(parts[1]),
            let seconds = Double(parts[2])
        {
            return hours * 3600 + minutes * 60 + seconds
        }

        let pattern = "(\\d+)\\s*h\\s*(\\d+)\\s*m?"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str))
        {
            if let hoursRange = Range(match.range(at: 1), in: str),
                let minutesRange = Range(match.range(at: 2), in: str),
                let hours = Double(str[hoursRange]),
                let minutes = Double(str[minutesRange])
            {
                return hours * 3600 + minutes * 60
            }
        }

        return nil
    }

    private func bookId(sourceId: String, path: String) -> String {
        let input = "\(sourceId)::\(path)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func migrateProgressIfNeeded(from oldId: String, to newId: String, sourceId: String) {
        let userDefaults = UserDefaults.standard

        let oldStableId = "smb:\(sourceId):\(oldId)"
        let newStableId = "smb:\(sourceId):\(newId)"

        let oldProgressKey = "bookProgress_\(oldStableId)"
        let newProgressKey = "bookProgress_\(newStableId)"

        let legacyOldKey = "bookProgress_\(oldId)"

        if userDefaults.dictionary(forKey: newProgressKey) != nil {
            return
        }

        if let oldProgress = userDefaults.dictionary(forKey: oldProgressKey) {
            AppLogger.network.info("[SMB Migration] Migrating progress from \(oldProgressKey) to \(newProgressKey)")
            userDefaults.set(oldProgress, forKey: newProgressKey)
            return
        }

        if let legacyProgress = userDefaults.dictionary(forKey: legacyOldKey) {
            AppLogger.network.info("[SMB Migration] Migrating progress from legacy key \(legacyOldKey) to \(newProgressKey)")
            userDefaults.set(legacyProgress, forKey: newProgressKey)
            return
        }
    }
}
