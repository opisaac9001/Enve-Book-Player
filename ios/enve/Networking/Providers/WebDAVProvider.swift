import AVFoundation
import CryptoKit
import Foundation
import Logging

final class WebDAVProvider: WholeSnapshotCatalogProvider, PlaybackSessionProvider, EbookDownloadProvider,
    @unchecked Sendable
{
    var connection: ServerConnection

    var capabilities: ProviderCapabilities {
        [.fullImport, .downloads, .backgroundOperation]
    }

    private struct WebDAVEbookFile {
        let entry: RemoteFileEntry
        let folderPath: String
        let folderEntries: [RemoteFileEntry]
    }

    private struct TorBoxCloudFile {
        let id: String
        let name: String
        let path: String
        let parentFolder: String
        let link: String
        let size: Int64?
        let cover: TorBoxCloudCover?
    }

    private struct TorBoxCloudCover {
        let path: String
        let parentFolder: String
        let link: String
        let rank: Int
    }

    private var bookSource: Book.BookSource {
        isTorBoxConnection ? .torbox : .webdav
    }

    private static let torBoxMaxListItems = 100_000
    private static let torBoxMaxAudioFiles = 100_000

    init(connection: ServerConnection) {
        self.connection = connection
    }

    func validateConnection() async throws -> Bool {
        let server = try await resolveServerConfig()
        AppLogger.network.info("Validating: \(server.baseURL.redacted)")
        AppLogger.network.info("Username: \(server.username ?? "<nil>")")
        let passLen = server.password?.count ?? 0
        AppLogger.network.info("Password: \(passLen > 0 ? "<set \(passLen) chars>" : "<nil>")")
        AppLogger.network.info("AuthType: \(server.authType.rawValue)")
        let path = server.rootPath.isEmpty ? "/" : server.rootPath
        _ = try await RemoteImportService.shared.listWebDAVDirectory(server: server, path: path)
        AppLogger.network.info("Connection validated successfully")
        return true
    }

    func fetchLibraries() async throws -> [Library] {
        let server = try await resolveServerConfig()
        let paths = normalizedIndexedPaths(from: server)
        guard !paths.isEmpty else { return [] }

        return paths.map { path in
            Library(
                id: libraryId(for: server, path: path),
                name: libraryName(for: server, path: path),
                type: "webdav",
                providerId: connection.id
            )
        }
    }

    func fetchBooks(libraryId: String) async throws -> [Book] {
        let server = try await resolveServerConfig()
        let paths = normalizedIndexedPaths(from: server)
        guard let rootPath = paths.first(where: { self.libraryId(for: server, path: $0) == libraryId }) else {
            return []
        }

        let scannedFolders = try await scanBookFolders(server: server, rootPath: rootPath)
        let ebookFiles = try await scanEbookFiles(server: server, rootPath: rootPath)
        let collapsedFolders = collapseDiscSubfolders(scannedFolders, rootPath: rootPath)
        AppLogger.network.info("After disc collapse: \(collapsedFolders.count) folders")
        let libraryName = libraryName(for: server, path: rootPath)
        let backendId = normalizedBackendId()
        var books: [Book] = []

        let metadataRootPath = effectiveMetadataRoot(rootPath: rootPath, folders: collapsedFolders)

        var parentsOfBookFolders = Set<String>()
        for folder in collapsedFolders {
            let parentPath = normalizedServerPath((folder.path as NSString).deletingLastPathComponent)
            if parentPath != folder.path {
                parentsOfBookFolders.insert(parentPath)
            }
        }

        let bookUnits = resolveBookUnits(
            from: collapsedFolders,
            server: server,
            rootPath: rootPath,
            parentsOfBookFolders: parentsOfBookFolders
        )
        AppLogger.network.info("resolveBookUnits produced \(bookUnits.count) book units")

        let ebookMetadataRootPath = effectiveMetadataRoot(rootPath: rootPath, folders: collapsedFolders)

        let totalUnits = bookUnits.count + ebookFiles.count
        await MainActor.run {
            AppState.shared.presentation.libraryImportProgress = LibraryImportProgress(
                libraryId: libraryId,
                libraryName: libraryName,
                loadedCount: 0,
                totalCount: totalUnits,
                isComplete: false
            )
        }

        for unit in bookUnits {
            let audioFiles = unit.audioFiles.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let tracks = audioFiles.enumerated().map { index, entry in
                AudioTrack(
                    index: index,
                    title: trackTitle(from: entry.name),
                    filePath: entry.path,
                    contentUrl: entry.contentURL ?? server.url(for: entry.path).absoluteString,
                    duration: 0,
                    startOffset: 0,
                    fileSize: entry.size,
                    format: (entry.name as NSString).pathExtension.lowercased(),
                    headers: self.getStreamingHeaders()
                )
            }

            let addedAt = audioFiles.compactMap(\.modifiedDate).max()

            let sidecarMetadata = await loadSidecarMetadataIfPresent(server: server, folder: unit.folder)

            let folderMeta = parseMetadataFromPath(unit.folder.path, rootPath: metadataRootPath)
            AppLogger.network.info(
                "Book '\(unit.folder.path)' -> metadataRoot='\(metadataRootPath)' -> author='\(folderMeta.author ?? "nil")', title='\(folderMeta.title ?? "nil")'"
            )

            var coverURL: URL?
            if let coverPath = sidecarMetadata?.coverImagePath {
                coverURL = server.url(for: coverPath)
            } else {
                coverURL = coverURLIfAvailable(server: server, folder: unit.folder)
            }

            let chaptersFromSidecar = sidecarMetadata?.chapters?.enumerated().map { index, localChap in
                Chapter(
                    id: localChap.id,
                    start: localChap.startTime,
                    end: localChap.endTime,
                    title: localChap.title,
                    index: index
                )
            }

            let bookTitle: String
            if unit.isSingleFileSplit, let singleFile = audioFiles.first {
                bookTitle = sidecarMetadata?.title ?? trackTitle(from: singleFile.name)
            } else {
                bookTitle = sidecarMetadata?.title ?? folderMeta.title ?? folderName(from: unit.folder.path)
            }

            let bookPath = unit.isSingleFileSplit ? (audioFiles.first?.path ?? unit.folder.path) : unit.folder.path

            let book = Book(
                id: bookId(for: server, path: bookPath),
                ratingKey: bookId(for: server, path: bookPath),
                title: bookTitle,
                author: sidecarMetadata?.author ?? folderMeta.author,
                narrator: sidecarMetadata?.narrator,
                thumb: coverURL?.absoluteString,
                partKey: nil,
                duration: sidecarMetadata?.duration,
                chapters: chaptersFromSidecar,
                currentChapterIndex: nil,
                source: bookSource,
                backendId: backendId,
                trackIndex: 0,
                filePath: bookPath,
                audioFileIno: nil,
                audioFileInos: nil,
                audioTracks: tracks,
                description: sidecarMetadata?.description,
                series: sidecarMetadata?.series ?? folderMeta.series,
                seriesNumber: sidecarMetadata?.seriesNumber ?? folderMeta.seriesNumber,
                publishedYear: sidecarMetadata?.publishedYear ?? folderMeta.publishedYear,
                genres: sidecarMetadata?.genres,
                publisher: sidecarMetadata?.publisher,
                isbn: sidecarMetadata?.isbn,
                asin: sidecarMetadata?.asin,
                addedAt: addedAt,
                libraryName: libraryName,
                backendName: connection.name,
                currentTime: 0,
                isFinished: false,
                lastUpdate: Date(),
                providerId: connection.id,
                libraryId: libraryId
            )

            books.append(book)

            let loadedCount = books.count
            if loadedCount % 25 == 0 || loadedCount == totalUnits {
                await MainActor.run {
                    AppState.shared.presentation.libraryImportProgress = LibraryImportProgress(
                        libraryId: libraryId,
                        libraryName: libraryName,
                        loadedCount: loadedCount,
                        totalCount: totalUnits,
                        isComplete: false
                    )
                }
            }
        }

        for ebookFile in ebookFiles {
            let syntheticFolder = WebDAVBookFolder(path: ebookFile.folderPath, audioFiles: [], entries: ebookFile.folderEntries)
            let sidecarMetadata = await loadSidecarMetadataIfPresent(server: server, folder: syntheticFolder)
            let folderMeta = parseMetadataFromPath(ebookFile.entry.path, rootPath: ebookMetadataRootPath)

            let remotePath = ebookFile.entry.path
            let theBookId = bookId(for: server, path: remotePath)
            let fallbackTitle = (ebookFile.entry.name as NSString).deletingPathExtension

            let storedMeta = try? await MetadataStorage.shared.loadMetadata(bookId: theBookId)
            let hasMeaningfulStoredData = storedMeta?.file.title != nil || storedMeta?.file.author != nil

            var coverURL: URL?
            if let coverPath = sidecarMetadata?.coverImagePath {
                coverURL = server.url(for: coverPath)
            } else if let storedCoverPath = storedMeta?.file.coverPath,
                FileManager.default.fileExists(atPath: storedCoverPath)
            {
                coverURL = URL(fileURLWithPath: storedCoverPath)
            } else {
                if storedMeta?.file.coverPath != nil {
                    if var mutableMeta = storedMeta {
                        mutableMeta.file.coverPath = nil
                        try? await MetadataStorage.shared.saveMetadata(mutableMeta)
                    }
                }
                coverURL = coverURLIfAvailable(server: server, folder: syntheticFolder)
            }

            let chaptersFromSidecar = sidecarMetadata?.chapters?.enumerated().map { index, localChap in
                Chapter(
                    id: localChap.id,
                    start: localChap.startTime,
                    end: localChap.endTime,
                    title: localChap.title,
                    index: index
                )
            }

            let ebookBook = Book(
                id: theBookId,
                ratingKey: theBookId,
                title: sidecarMetadata?.title ?? storedMeta?.file.title ?? folderMeta.title ?? fallbackTitle,
                author: sidecarMetadata?.author ?? storedMeta?.file.author ?? folderMeta.author,
                narrator: nil,
                thumb: coverURL?.absoluteString,
                partKey: nil,
                duration: nil,
                chapters: chaptersFromSidecar,
                currentChapterIndex: nil,
                source: bookSource,
                backendId: backendId,
                trackIndex: nil,
                filePath: remotePath,
                audioFileIno: nil,
                audioFileInos: nil,
                audioTracks: nil,
                mediaType: .ebook,
                ebookFileURL: nil,
                description: sidecarMetadata?.description ?? storedMeta?.file.description,
                series: sidecarMetadata?.series ?? storedMeta?.file.series ?? folderMeta.series,
                seriesNumber: sidecarMetadata?.seriesNumber ?? storedMeta?.file.seriesNumber ?? folderMeta.seriesNumber,
                publishedYear: sidecarMetadata?.publishedYear ?? storedMeta?.file.year ?? folderMeta.publishedYear,
                genres: sidecarMetadata?.genres ?? storedMeta?.file.genres,
                publisher: sidecarMetadata?.publisher ?? storedMeta?.file.publisher,
                isbn: sidecarMetadata?.isbn ?? storedMeta?.file.isbn,
                asin: sidecarMetadata?.asin ?? storedMeta?.file.asin,
                addedAt: ebookFile.entry.modifiedDate,
                libraryName: libraryName,
                backendName: connection.name,
                currentTime: 0,
                isFinished: false,
                lastUpdate: Date(),
                providerId: connection.id,
                libraryId: libraryId
            )

            books.append(ebookBook)

            if sidecarMetadata == nil && !hasMeaningfulStoredData {
                let capturedBook = ebookBook
                let capturedServer = server
                Task.detached(priority: .utility) { [weak self] in
                    guard let self else { return }
                    await self.extractAndCacheEbookMetadata(for: capturedBook, server: capturedServer)
                }
            }

            let loadedCount = books.count
            if loadedCount % 25 == 0 || loadedCount == totalUnits {
                await MainActor.run {
                    AppState.shared.presentation.libraryImportProgress = LibraryImportProgress(
                        libraryId: libraryId,
                        libraryName: libraryName,
                        loadedCount: loadedCount,
                        totalCount: totalUnits,
                        isComplete: false
                    )
                }
            }
        }

        await MainActor.run {
            AppState.shared.presentation.libraryImportProgress = LibraryImportProgress(
                libraryId: libraryId,
                libraryName: libraryName,
                loadedCount: books.count,
                totalCount: totalUnits,
                isComplete: true,
                phase: .indexing
            )
        }

        let capturedBooks = books
        let capturedServer = server
        let capturedLibraryId = libraryId
        let capturedLibraryName = libraryName
        let shouldDeferPrefetch = isPremiumizeConnection()
        Task.detached(priority: shouldDeferPrefetch ? .background : .utility) { [weak self] in
            guard let self else { return }
            if shouldDeferPrefetch {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            await self.prefetchChaptersAndDurations(
                for: capturedBooks,
                server: capturedServer,
                libraryId: capturedLibraryId,
                libraryName: capturedLibraryName,
                reportProgress: !shouldDeferPrefetch
            )
        }

        return books
    }

    func fetchRecentBooks(libraryId: String, limit: Int) async throws -> [Book] {
        return []
    }

    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        if let existing = book.ebookFileURL, FileManager.default.fileExists(atPath: existing.path) {
            onProgress?(1)
            return existing
        }

        guard book.mediaType == .ebook,
            let remotePath = book.filePath
        else {
            throw ProviderError.invalidURL
        }

        let server = try await resolveServerConfig()
        let remoteURL = server.url(for: remotePath)

        let filename = (remotePath as NSString).lastPathComponent

        let username = server.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = (server.password ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let credential: URLCredential? =
            !username.isEmpty
            ? URLCredential(user: username, password: password, persistence: .forSession)
            : nil

        let request = URLRequest(url: remoteURL)
        let response: URLResponse
        let tempURL: URL

        if let onProgress {

            let delegate = URLSessionDownloadProgressDelegate(progressHandler: onProgress, credential: credential)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 300
            let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (url, http) = try await delegate.awaitResult {
                    session.downloadTask(with: request)
                }
                tempURL = url
                response = http
            } catch {
                throw error
            }
        } else {
            let session: URLSession
            let needsInvalidation: Bool
            if !username.isEmpty {
                let challengeDelegate = ProviderWebDAVAuthDelegate(username: username, password: password)
                let config = URLSessionConfiguration.default
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 300
                session = URLSession(configuration: config, delegate: challengeDelegate, delegateQueue: nil)
                needsInvalidation = true
            } else {
                session = URLSession.shared
                needsInvalidation = false
            }
            do {
                (tempURL, response) = try await session.download(for: request)
            } catch {
                if needsInvalidation { session.finishTasksAndInvalidate() }
                throw error
            }
            if needsInvalidation { session.finishTasksAndInvalidate() }
        }
        guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            try? FileManager.default.removeItem(at: tempURL)
            throw ProviderError.invalidResponse
        }

        return try LocalEbookImporter.shared.cacheRemoteEbook(
            tempURL: tempURL,
            preferredFilename: filename,
            bookIdentifier: book.id
        )
    }

    func fetchCollections(libraryId: String?) async throws -> [Collection] {
        return []
    }

    func fetchSeries(libraryId: String) async throws -> [Series] {
        return []
    }

    func fetchUserMediaProgress(libraryId: String) async throws -> [UserMediaProgress] {
        return []
    }

    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {
        guard let book = await AppState.shared.bookStore.book(byBookId: bookId) else {
            throw ProviderError.invalidResponse
        }

        var updatedBook = book
        let bookDuration = book.duration ?? 0

        AppLogger.network.info("[WebDAV] Fetching chapters for book (force refresh)...")
        let session = try await buildPlaybackSession(for: book)
        var chapters: [Chapter] = []

        if let audioTracks = book.audioTracks, audioTracks.count > 1 {
            chapters = session.chapters
            AppLogger.network.info("[WebDAV] Multi-file book: Built \(chapters.count) chapters from tracks")
        } else if let firstTrack = book.audioTracks?.first, let contentUrl = firstTrack.contentUrl, let audioURL = URL(string: contentUrl) {
            AppLogger.network.info("[WebDAV] Single-file book: Attempting to extract embedded chapters from audio file...")
            do {
                let embeddedChapters = try await extractChaptersFromAudioFile(streamURL: audioURL, bookDuration: bookDuration)
                if !embeddedChapters.isEmpty {
                    chapters = embeddedChapters
                    AppLogger.network.info("Extracted \(chapters.count) embedded chapters from audio file")
                } else {
                    chapters = session.chapters
                    AppLogger.network.info("No embedded chapters found, using file-based chapters: \(chapters.count)")
                }
            } catch {
                AppLogger.network.error("Chapter extraction failed: \(error.localizedDescription), using file-based chapters")
                chapters = session.chapters
            }
        } else {
            chapters = session.chapters
        }

        updatedBook = Book(
            id: updatedBook.id,
            ratingKey: updatedBook.ratingKey,
            title: updatedBook.title,
            author: updatedBook.author,
            narrator: updatedBook.narrator,
            thumb: updatedBook.thumb,
            partKey: updatedBook.partKey,
            duration: updatedBook.duration,
            chapters: chapters,
            currentChapterIndex: updatedBook.currentChapterIndex,
            source: updatedBook.source,
            backendId: updatedBook.backendId,
            trackIndex: updatedBook.trackIndex,
            filePath: updatedBook.filePath,
            audioFileIno: updatedBook.audioFileIno,
            audioFileInos: updatedBook.audioFileInos,
            audioTracks: updatedBook.audioTracks,
            description: updatedBook.description,
            series: updatedBook.series,
            seriesNumber: updatedBook.seriesNumber,
            publishedYear: updatedBook.publishedYear,
            genres: updatedBook.genres,
            publisher: updatedBook.publisher,
            isbn: updatedBook.isbn,
            asin: updatedBook.asin,
            addedAt: updatedBook.addedAt,
            libraryName: updatedBook.libraryName,
            backendName: updatedBook.backendName,
            currentTime: updatedBook.currentTime,
            isFinished: updatedBook.isFinished,
            lastUpdate: updatedBook.lastUpdate,
            providerId: updatedBook.providerId,
            libraryId: updatedBook.libraryId
        )

        let totalDuration = session.audioTracks.reduce(0.0) { $0 + $1.duration }
        let isMultiTrackBook = (updatedBook.audioTracks?.count ?? 0) > 1
        if shouldUseAggregatedDuration(
            currentDuration: updatedBook.duration,
            aggregatedDuration: totalDuration,
            isMultiTrack: isMultiTrackBook
        ) {
            updatedBook = Book(
                id: updatedBook.id,
                ratingKey: updatedBook.ratingKey,
                title: updatedBook.title,
                author: updatedBook.author,
                narrator: updatedBook.narrator,
                thumb: updatedBook.thumb,
                partKey: updatedBook.partKey,
                duration: totalDuration,
                chapters: updatedBook.chapters,
                currentChapterIndex: updatedBook.currentChapterIndex,
                source: updatedBook.source,
                backendId: updatedBook.backendId,
                trackIndex: updatedBook.trackIndex,
                filePath: updatedBook.filePath,
                audioFileIno: updatedBook.audioFileIno,
                audioFileInos: updatedBook.audioFileInos,
                audioTracks: updatedBook.audioTracks,
                description: updatedBook.description,
                series: updatedBook.series,
                seriesNumber: updatedBook.seriesNumber,
                publishedYear: updatedBook.publishedYear,
                genres: updatedBook.genres,
                publisher: updatedBook.publisher,
                isbn: updatedBook.isbn,
                asin: updatedBook.asin,
                addedAt: updatedBook.addedAt,
                libraryName: updatedBook.libraryName,
                backendName: updatedBook.backendName,
                currentTime: updatedBook.currentTime,
                isFinished: updatedBook.isFinished,
                lastUpdate: updatedBook.lastUpdate,
                providerId: updatedBook.providerId,
                libraryId: updatedBook.libraryId
            )
        }

        if updatedBook.author == nil || updatedBook.duration == nil || updatedBook.duration == 0 {
            let server = try await resolveServerConfig()
            if let firstTrack = updatedBook.audioTracks?.first, let contentUrl = firstTrack.contentUrl,
                let audioURL = URL(string: contentUrl)
            {
                if let embedded = try? await FileMetadataExtractor.shared.extractMetadataFromRemoteStream(
                    streamURL: audioURL,
                    headers: streamingHeaders(for: server),
                    timeout: 15.0
                ) {
                    let meta = localBookMetadata(from: embedded, fallbackTitle: updatedBook.title)
                    let isMultiTrack = (updatedBook.audioTracks?.count ?? 0) > 1
                    let resolvedDuration: TimeInterval?
                    if isMultiTrack {
                        resolvedDuration = updatedBook.duration
                    } else {
                        resolvedDuration = meta.duration ?? updatedBook.duration
                    }

                    updatedBook = Book(
                        id: updatedBook.id,
                        ratingKey: updatedBook.ratingKey,
                        title: meta.title,
                        author: meta.author ?? updatedBook.author,
                        narrator: meta.narrator ?? updatedBook.narrator,
                        thumb: updatedBook.thumb,
                        partKey: updatedBook.partKey,
                        duration: resolvedDuration,
                        chapters: updatedBook.chapters,
                        currentChapterIndex: updatedBook.currentChapterIndex,
                        source: updatedBook.source,
                        backendId: updatedBook.backendId,
                        trackIndex: updatedBook.trackIndex,
                        filePath: updatedBook.filePath,
                        audioFileIno: updatedBook.audioFileIno,
                        audioFileInos: updatedBook.audioFileInos,
                        audioTracks: updatedBook.audioTracks,
                        description: meta.description ?? updatedBook.description,
                        series: meta.series ?? updatedBook.series,
                        seriesNumber: meta.seriesNumber ?? updatedBook.seriesNumber,
                        publishedYear: meta.publishedYear ?? updatedBook.publishedYear,
                        genres: meta.genres ?? updatedBook.genres,
                        publisher: updatedBook.publisher,
                        isbn: meta.isbn ?? updatedBook.isbn,
                        asin: meta.asin ?? updatedBook.asin,
                        addedAt: updatedBook.addedAt,
                        libraryName: updatedBook.libraryName,
                        backendName: updatedBook.backendName,
                        currentTime: updatedBook.currentTime,
                        isFinished: updatedBook.isFinished,
                        lastUpdate: updatedBook.lastUpdate,
                        providerId: updatedBook.providerId,
                        libraryId: updatedBook.libraryId
                    )
                }
            }
        }

        return updatedBook
    }

    func getAudioURL(for book: Book) -> URL? {
        if let track = book.audioTracks?.first,
            let contentUrl = track.contentUrl
        {
            return URL(string: contentUrl)
        }

        guard let path = book.filePath else { return nil }
        return URL(string: path)
    }

    func getStreamingHeaders() -> [String: String] {
        let username = isTorBoxConnection ? "torbox" : (connection.username ?? "")
        guard !username.isEmpty else { return [:] }
        let password =
            isTorBoxConnection
            ? (connection.token ?? connection.password ?? "")
            : (connection.password ?? connection.token ?? "")
        let credentials = "\(username):\(password)"
        guard let data = credentials.data(using: .utf8) else { return [:] }
        return ["Authorization": "Basic \(data.base64EncodedString())"]
    }

    func startPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        return try await buildPlaybackSession(for: book)
    }

    func updatePlaybackProgress(
        book: Book,
        sessionId: String?,
        currentTime: TimeInterval,
        isFinished: Bool,
        timeListened: TimeInterval
    ) async throws {
        AppLogger.sync.debug(
            "Progress sync not supported for WebDAV bookId=\(DiagnosticLogSanitizer.identifier(for: book.stableId)); progress is local-only"
        )
    }

    private func resolveServerConfig() async throws -> WebDAVServerConfig {
        let config: WebDAVServerConfig? = await MainActor.run {
            RemoteImportService.shared.webDAVServers.first { $0.id == connection.id.uuidString }
        }

        if var config {
            if isTorBoxConnection {
                config.baseURL = torBoxWebDAVBaseURL()
                config.username = "torbox"
                config.password = connection.token ?? connection.password ?? config.password
                config.authType = .basic
            } else {
                let username = connection.username
                let password = connection.password ?? connection.token
                if let username, !username.isEmpty {
                    config.username = username
                }
                if let password, !password.isEmpty {
                    config.password = password
                }
            }
            return config
        }

        let baseURL: URL
        if isTorBoxConnection {
            baseURL = torBoxWebDAVBaseURL()
        } else if let resolvedURL = URL(string: connection.url) {
            baseURL = resolvedURL
        } else {
            throw ProviderError.invalidURL
        }

        let password = connection.password ?? connection.token
        let authType: WebDAVServerConfig.WebDAVAuthType
        let username: String?
        if isTorBoxConnection {
            username = "torbox"
            authType = .basic
        } else {
            username = connection.username
            authType = (connection.username != nil || password != nil) ? .basic : .none
        }

        let newConfig = WebDAVServerConfig(
            id: connection.id.uuidString,
            name: connection.name,
            baseURL: baseURL,
            username: username,
            password: password,
            authType: authType,
            rootPath: "/",
            indexedPaths: [],
            isEnabled: true,
            lastConnected: Date(),
            autoSync: false
        )

        await MainActor.run {
            RemoteImportService.shared.saveWebDAVServer(newConfig)
        }

        return newConfig
    }

    private var isTorBoxConnection: Bool {
        if connection.type == .torbox { return true }
        guard let host = URL(string: connection.url)?.host?.lowercased() else { return false }
        return host.contains("torbox")
    }

    private func torBoxWebDAVBaseURL() -> URL {
        URL(string: "https://webdav.torbox.app")!
    }

    private func normalizedIndexedPaths(from server: WebDAVServerConfig) -> [String] {
        var paths = server.indexedPaths
        if paths.isEmpty {
            paths = [server.rootPath]
        }

        let normalized = paths.map { path -> String in
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "/" }
            var result = trimmed
            if !result.hasPrefix("/") { result = "/" + result }
            if result.count > 1 && result.hasSuffix("/") { result.removeLast() }
            return result
        }

        let unique = Array(Set(normalized))
        return unique.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func normalizedBackendId() -> String {
        connection.url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func libraryId(for server: WebDAVServerConfig, path: String) -> String {
        let signature = "\(server.baseURL.absoluteString)|\(path)"
        return "webdav:\(hashString(signature))"
    }

    private func bookId(for server: WebDAVServerConfig, path: String) -> String {
        let signature = "\(server.baseURL.absoluteString)|\(path)"
        return "webdav:\(hashString(signature))"
    }

    private func libraryName(for server: WebDAVServerConfig, path: String) -> String {
        if path == "/" || path.isEmpty {
            return server.name
        }
        if isPremiumizeConnection() {
            let folder = folderName(from: path)
            return "\(connection.name) - \(folder)"
        }
        return folderName(from: path)
    }

    func folderName(from path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return (trimmed as NSString).lastPathComponent
    }

    private func effectiveMetadataRoot(rootPath: String, folders: [WebDAVBookFolder]) -> String {
        let normalizedRoot = normalizedServerPath(rootPath)
        guard !folders.isEmpty else { return normalizedRoot }

        let allComponents = folders.map { folder -> [String] in
            let p = normalizedServerPath(folder.path)
            return p.split(separator: "/").map(String.init)
        }

        guard let first = allComponents.first else { return normalizedRoot }

        var commonPrefix: [String] = first
        for components in allComponents.dropFirst() {
            var newPrefix: [String] = []
            for (a, b) in zip(commonPrefix, components) {
                if a == b { newPrefix.append(a) } else { break }
            }
            commonPrefix = newPrefix
            if commonPrefix.isEmpty { break }
        }

        let folderPathSet = Set(folders.map { normalizedServerPath($0.path) })
        while !commonPrefix.isEmpty {
            let candidate = "/" + commonPrefix.joined(separator: "/")
            if !folderPathSet.contains(normalizedServerPath(candidate)) {
                break
            }
            commonPrefix.removeLast()
        }

        let effectivePath = commonPrefix.isEmpty ? "/" : ("/" + commonPrefix.joined(separator: "/"))
        let normalizedEffective = normalizedServerPath(effectivePath)

        if normalizedEffective.count > normalizedRoot.count {
            AppLogger.network.info("Effective metadata root: \(normalizedEffective) (original: \(normalizedRoot))")
            return normalizedEffective
        }
        return normalizedRoot
    }
    private func trackTitle(from name: String) -> String {
        (name as NSString).deletingPathExtension
    }

    private func extractAndCacheEbookMetadata(for book: Book, server: WebDAVServerConfig) async {
        guard let remotePath = book.filePath else { return }

        let diagnosticID = DiagnosticLogSanitizer.identifier(for: book.stableId)
        AppLogger.network.debug("[WebDAV] Extracting embedded metadata bookDiagnosticID=\(diagnosticID)")

        do {
            let remoteURL = server.url(for: remotePath)
            let (data, response) = try await webDAVData(for: remoteURL, server: server)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                AppLogger.network.error("Metadata download failed bookDiagnosticID=\(diagnosticID)")
                return
            }

            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("webdav_meta_\(book.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            let filename = (remotePath as NSString).lastPathComponent
            let tmpFile = tmpDir.appendingPathComponent(filename)
            try data.write(to: tmpFile, options: .atomic)

            let extracted = try await LocalEbookImporter.shared.extractMetadata(from: tmpFile)

            var storedMeta =
                (try? await MetadataStorage.shared.loadMetadata(bookId: book.id))
                ?? MetadataManager.shared.initializeBookMetadata(from: book)

            storedMeta.file.title = extracted.title.isEmpty ? nil : extracted.title
            storedMeta.file.author = extracted.author
            storedMeta.file.description = extracted.description
            storedMeta.file.publisher = extracted.publisher
            storedMeta.file.genres = extracted.genres
            storedMeta.file.year = extracted.publishedYear
            storedMeta.file.isbn = extracted.isbn
            storedMeta.file.asin = extracted.asin

            if let tmpCoverPath = extracted.coverImagePath,
                FileManager.default.fileExists(atPath: tmpCoverPath)
            {
                let coverData = try Data(contentsOf: URL(fileURLWithPath: tmpCoverPath))
                if let permanentCoverURL = saveCoverToCache(data: coverData, bookId: book.id) {
                    storedMeta.file.coverPath = permanentCoverURL.path
                }
            }

            try await MetadataStorage.shared.saveMetadata(storedMeta)

            await MainActor.run {
                NotificationCenter.default.post(name: .metadataUpdated, object: book.id)
            }
            AppLogger.network.debug("Background metadata saved bookDiagnosticID=\(diagnosticID)")
        } catch {
            AppLogger.network.error(
                "Background metadata extraction failed bookDiagnosticID=\(diagnosticID): \(error.localizedDescription)"
            )
        }
    }

    private func hashString(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func coverURLIfAvailable(server: WebDAVServerConfig, folder: WebDAVBookFolder) -> URL? {
        if let coverURL = folder.coverURL.flatMap(URL.init(string:)) {
            return coverURL
        }
        guard let coverEntry = folder.entries.first(where: { $0.isCoverImage }) else { return nil }
        return server.url(for: coverEntry.path)
    }

    private func loadSidecarMetadataIfPresent(server: WebDAVServerConfig, folder: WebDAVBookFolder) async -> LocalBookMetadata? {
        guard let sidecarEntry = folder.entries.first(where: { $0.isMetadataFile }) else { return nil }
        return try? await loadSidecarMetadata(server: server, entry: sidecarEntry)
    }

    private func resolveRemoteMetadata(server: WebDAVServerConfig, folder: WebDAVBookFolder) async -> LocalBookMetadata? {
        if let sidecarEntry = folder.entries.first(where: { $0.isMetadataFile }) {
            if let metadata = try? await loadSidecarMetadata(server: server, entry: sidecarEntry) {
                return metadata
            }
        }

        guard let firstAudio = folder.audioFiles.first else { return nil }
        let audioURL = server.url(for: firstAudio.path)
        do {
            let embedded = try await FileMetadataExtractor.shared.extractMetadataFromRemoteStream(
                streamURL: audioURL,
                headers: streamingHeaders(for: server),
                timeout: 10.0
            )
            return localBookMetadata(from: embedded, fallbackTitle: folderName(from: folder.path))
        } catch {
            return nil
        }
    }

    private func loadSidecarMetadata(server: WebDAVServerConfig, entry: RemoteFileEntry) async throws -> LocalBookMetadata? {
        let url = server.url(for: entry.path)
        var request = URLRequest(url: url)
        let headers = streamingHeaders(for: server)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let local = try? decoder.decode(LocalBookMetadata.self, from: data) {
            return local
        }

        if let abs = try? decoder.decode(AudiobookshelfMetadata.self, from: data) {
            return abs.toLocalBookMetadata()
        }

        if let generic = try? decoder.decode(GenericBookMetadata.self, from: data) {
            return generic.toLocalBookMetadata()
        }

        return nil
    }

    private func localBookMetadata(from embedded: FileMetadataLayer, fallbackTitle: String) -> LocalBookMetadata {
        LocalBookMetadata(
            title: embedded.title ?? embedded.folderName ?? embedded.fileName ?? fallbackTitle,
            author: embedded.author,
            narrator: embedded.narrator,
            description: embedded.description,
            series: embedded.series,
            seriesNumber: embedded.seriesNumber,
            publishedYear: embedded.year,
            genres: embedded.genres?.isEmpty == false ? embedded.genres : nil,
            publisher: embedded.publisher,
            isbn: embedded.isbn,
            asin: embedded.asin,
            duration: embedded.duration,
            chapters: nil,
            coverImagePath: nil
        )
    }

    private func streamingHeaders(for server: WebDAVServerConfig) -> [String: String] {
        guard let username = server.username, !username.isEmpty else { return [:] }
        let password = server.password ?? ""
        let credentials = "\(username):\(password)"
        guard let data = credentials.data(using: .utf8) else { return [:] }
        return ["Authorization": "Basic \(data.base64EncodedString())"]
    }

    private func scanBookFolders(server: WebDAVServerConfig, rootPath: String) async throws -> [WebDAVBookFolder] {
        if isTorBoxConnection {
            return try await scanTorBoxBookFolders(server: server, rootPath: rootPath)
        }

        return try await scanWebDAVBookFolders(server: server, rootPath: rootPath)
    }

    private func scanWebDAVBookFolders(server: WebDAVServerConfig, rootPath: String) async throws -> [WebDAVBookFolder] {
        let collector = BookFolderCollector()

        let maxConcurrency = 4
        var queue: [String] = [normalizedServerPath(rootPath)]
        var batchCount = 0

        while !queue.isEmpty {
            let batch = Array(queue.prefix(maxConcurrency))
            queue.removeFirst(min(maxConcurrency, queue.count))

            batchCount += 1
            if batchCount > 1 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            await withTaskGroup(of: (String, [RemoteFileEntry])?.self) { group in
                for path in batch {
                    let normalizedPath = normalizedServerPath(path)
                    guard await collector.markVisited(normalizedPath) else { continue }

                    group.addTask {
                        do {
                            let entries = try await RemoteImportService.shared.listWebDAVDirectory(server: server, path: normalizedPath)
                            return (normalizedPath, entries)
                        } catch {
                            AppLogger.network.error("Skipping '\(normalizedPath)' - PROPFIND failed: \(error.localizedDescription)")
                            return nil
                        }
                    }
                }

                for await result in group {
                    guard let (dirPath, entries) = result else { continue }

                    let audioFiles = entries.filter { $0.isAudioFile }
                    if !audioFiles.isEmpty {
                        await collector.addFolder(WebDAVBookFolder(path: dirPath, audioFiles: audioFiles, entries: entries))
                    }

                    let subdirs = entries.filter { $0.isDirectory }
                    for subdir in subdirs {
                        let childPath = normalizedServerPath(subdir.path)
                        if childPath != dirPath {
                            queue.append(childPath)
                        }
                    }
                }
            }
        }

        let scannedResult = await collector.results
        AppLogger.network.info("scanBookFolders found \(scannedResult.count) folders with audio (\(batchCount) PROPFIND batches)")
        for f in scannedResult {
            AppLogger.network.debug(
                "Folder diagnosticID=\(DiagnosticLogSanitizer.identifier(for: f.path)) audio=\(f.audioFiles.count) entries=\(f.entries.count)"
            )
        }
        return scannedResult
    }

    private func scanTorBoxBookFolders(server: WebDAVServerConfig, rootPath: String) async throws -> [WebDAVBookFolder] {
        async let webDAVFolders = scanWebDAVBookFolders(server: server, rootPath: rootPath)
        async let cloudFiles = fetchTorBoxAudioFiles(rootPath: rootPath)
        async let webDAVCovers = scanTorBoxCoverFiles(server: server, rootPath: rootPath)

        let folders = try await webDAVFolders
        let covers = await webDAVCovers
        var files = await cloudFiles
        if !covers.isEmpty {
            files = attachTorBoxCovers(files, covers: covers)
        }

        guard !files.isEmpty else { return folders }

        let merged = applyTorBoxFolderCovers(covers, to: mergeTorBoxFiles(files, into: folders))
        AppLogger.network.info(
            "TorBox scan merged WebDAV folders=\(folders.count), API files=\(files.count), merged folders=\(merged.count)"
        )
        return merged
    }

    private func fetchTorBoxAudioFiles(rootPath: String) async -> [TorBoxCloudFile] {
        let token = (connection.token ?? connection.password ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return [] }

        let files = await withTaskGroup(of: [TorBoxCloudFile].self) { group in
            group.addTask {
                await self.fetchTorBoxDownloadTypeAudioFiles(
                    token: token,
                    typePath: "torrents",
                    idParameter: "torrent_id",
                    idPrefix: "tb-torrent"
                )
            }
            group.addTask {
                await self.fetchTorBoxDownloadTypeAudioFiles(
                    token: token,
                    typePath: "usenet",
                    idParameter: "usenet_id",
                    idPrefix: "tb-usenet"
                )
            }
            group.addTask {
                await self.fetchTorBoxDownloadTypeAudioFiles(token: token, typePath: "webdl", idParameter: "web_id", idPrefix: "tb-webdl")
            }

            var collected: [TorBoxCloudFile] = []
            for await result in group {
                collected.append(contentsOf: result)
            }
            return collected
        }

        var merged: [String: TorBoxCloudFile] = [:]
        for file in files {
            merged[torBoxPathKey(file.path)] = file
        }

        let filtered = filterTorBoxFiles(Array(merged.values), rootPath: rootPath)
        AppLogger.network.info("TorBox API scan found \(files.count) audio files, \(filtered.count) inside \(rootPath)")
        return filtered
    }

    private func scanTorBoxCoverFiles(server: WebDAVServerConfig, rootPath: String) async -> [TorBoxCloudCover] {
        let maxConcurrency = 4
        var queue: [String] = [normalizedServerPath(rootPath)]
        var visited = Set<String>()
        var covers: [TorBoxCloudCover] = []

        while !queue.isEmpty {
            let batch = Array(queue.prefix(maxConcurrency))
            queue.removeFirst(min(maxConcurrency, queue.count))

            await withTaskGroup(of: (String, [RemoteFileEntry])?.self) { group in
                for path in batch {
                    let normalizedPath = normalizedServerPath(path)
                    guard visited.insert(normalizedPath).inserted else { continue }

                    group.addTask {
                        do {
                            let entries = try await RemoteImportService.shared.listWebDAVDirectory(server: server, path: normalizedPath)
                            return (normalizedPath, entries)
                        } catch {
                            AppLogger.network.error("TorBox cover scan skipping '\(normalizedPath)': \(error.localizedDescription)")
                            return nil
                        }
                    }
                }

                for await result in group {
                    guard let (dirPath, entries) = result else { continue }

                    for entry in entries where entry.isCoverImage {
                        covers.append(
                            TorBoxCloudCover(
                                path: entry.path,
                                parentFolder: dirPath,
                                link: server.url(for: entry.path).absoluteString,
                                rank: torBoxCoverRank(entry.name)
                            )
                        )
                    }

                    for subdir in entries where subdir.isDirectory {
                        let childPath = normalizedServerPath(subdir.path)
                        if childPath != dirPath {
                            queue.append(childPath)
                        }
                    }
                }
            }
        }

        AppLogger.network.info("TorBox WebDAV cover scan found \(covers.count) cover files")
        return covers
    }

    private func fetchTorBoxDownloadTypeAudioFiles(
        token: String,
        typePath: String,
        idParameter: String,
        idPrefix: String
    ) async -> [TorBoxCloudFile] {
        var files: [TorBoxCloudFile] = []
        var covers: [TorBoxCloudCover] = []
        var offset = 0
        let limit = 1000
        var seenItemIds = Set<String>()

        while offset < Self.torBoxMaxListItems && files.count < Self.torBoxMaxAudioFiles {
            guard
                let url = torBoxAPIURL(
                    pathSegments: [typePath, "mylist"],
                    queryItems: [
                        URLQueryItem(name: "limit", value: String(limit)),
                        URLQueryItem(name: "offset", value: String(offset)),
                        URLQueryItem(name: "bypass_cache", value: "true"),
                        URLQueryItem(name: "token", value: token),
                    ]
                )
            else { return attachTorBoxCovers(files, covers: covers) }

            let items = await fetchTorBoxJSONArray(url: url, token: token, key: "data")
            if items.isEmpty { break }

            var newItemCount = 0
            for item in items {
                guard let itemId = stringValue(item["id"]) ?? stringValue(item["id_"]),
                    seenItemIds.insert(itemId).inserted
                else { continue }
                newItemCount += 1

                let hasAvailabilityFlag = item["cached"] != nil || item["download_present"] != nil || item["download_finished"] != nil
                if hasAvailabilityFlag,
                    boolValue(item["cached"]) != true,
                    boolValue(item["download_present"]) != true,
                    boolValue(item["download_finished"]) != true
                {
                    continue
                }

                let itemName = decodeTorBoxPath(
                    stringValue(item["name"]) ?? stringValue(item["filename"]) ?? stringValue(item["hash"]) ?? itemId
                )
                let fileItems = (item["files"] as? [[String: Any]]) ?? []
                for file in fileItems {
                    guard let fileId = stringValue(file["id"]) ?? stringValue(file["id_"]),
                        let fullPath = torBoxDisplayPath(file: file, itemName: itemName),
                        let link = torBoxRequestDownloadURL(
                            token: token,
                            typePath: typePath,
                            idParameter: idParameter,
                            itemId: itemId,
                            fileId: fileId
                        )?.absoluteString
                    else { continue }

                    let name = decodeTorBoxPathSegment(stringValue(file["short_name"]) ?? (fullPath as NSString).lastPathComponent)
                    let parent = torBoxParentPath(for: fullPath, fallback: itemName)

                    if isTorBoxCoverFile(name) {
                        covers.append(TorBoxCloudCover(path: fullPath, parentFolder: parent, link: link, rank: torBoxCoverRank(name)))
                        continue
                    }

                    guard isTorBoxAudioFile(name) else { continue }
                    files.append(
                        TorBoxCloudFile(
                            id: "\(idPrefix)-\(itemId)-\(fileId)",
                            name: name,
                            path: fullPath,
                            parentFolder: parent,
                            link: link,
                            size: int64Value(file["size"]),
                            cover: nil
                        )
                    )
                }
            }

            if newItemCount == 0 { break }
            offset += items.count
        }

        AppLogger.network.info("TorBox \(typePath) API scan: items=\(seenItemIds.count), audio=\(files.count), covers=\(covers.count)")
        return attachTorBoxCovers(files, covers: covers)
    }

    private func mergeTorBoxFiles(_ files: [TorBoxCloudFile], into folders: [WebDAVBookFolder]) -> [WebDAVBookFolder] {
        var foldersByPath: [String: WebDAVBookFolder] = [:]
        for folder in folders {
            foldersByPath[normalizedServerPath(folder.path)] = folder
        }

        for group in Dictionary(grouping: files, by: { normalizedServerPath($0.parentFolder) }) {
            let folderPath = group.key
            let existing = foldersByPath[folderPath]
            var folderCoverURL = existing?.coverURL
            var audioByPath: [String: RemoteFileEntry] = [:]
            for audioFile in existing?.audioFiles ?? [] {
                audioByPath[torBoxPathKey(audioFile.path)] = audioFile
            }
            var entriesByPath: [String: RemoteFileEntry] = [:]
            for entry in existing?.entries ?? [] {
                entriesByPath[torBoxPathKey(entry.path)] = entry
            }

            for file in group.value {
                let entry = RemoteFileEntry(
                    id: file.id,
                    name: file.name,
                    path: normalizedServerPath(file.path),
                    isDirectory: false,
                    size: file.size,
                    mimeType: mimeType(for: file.name),
                    contentURL: file.link
                )
                let key = torBoxPathKey(entry.path)
                audioByPath[key] = entry
                entriesByPath[key] = entry

                if let cover = file.cover {
                    folderCoverURL = folderCoverURL ?? cover.link
                    let coverName = (cover.path as NSString).lastPathComponent
                    let coverEntry = RemoteFileEntry(
                        id: "tb-cover-\(hashString(cover.path))",
                        name: coverName,
                        path: cover.link,
                        isDirectory: false,
                        size: nil,
                        mimeType: mimeType(for: coverName)
                    )
                    entriesByPath[torBoxPathKey(cover.link)] = coverEntry
                }
            }

            let audioFiles = audioByPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            let entries = entriesByPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            foldersByPath[folderPath] = WebDAVBookFolder(
                path: folderPath,
                audioFiles: audioFiles,
                entries: entries,
                coverURL: folderCoverURL
            )
        }

        return foldersByPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func applyTorBoxFolderCovers(_ covers: [TorBoxCloudCover], to folders: [WebDAVBookFolder]) -> [WebDAVBookFolder] {
        guard !covers.isEmpty else { return folders }

        let coversByFolder = Dictionary(grouping: covers, by: { torBoxPathKey($0.parentFolder) })
            .mapValues { covers in
                covers.sorted {
                    if $0.rank != $1.rank { return $0.rank < $1.rank }
                    return $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }.first
            }

        return folders.map { folder in
            if folder.coverURL != nil || folder.entries.contains(where: { $0.isCoverImage }) {
                return folder
            }
            guard let cover = firstNotNil(folderAndAncestors(folder.path), transform: { coversByFolder[torBoxPathKey($0)] ?? nil }) else {
                return folder
            }
            return WebDAVBookFolder(path: folder.path, audioFiles: folder.audioFiles, entries: folder.entries, coverURL: cover.link)
        }
    }

    private func attachTorBoxCovers(_ files: [TorBoxCloudFile], covers: [TorBoxCloudCover]) -> [TorBoxCloudFile] {
        guard !files.isEmpty, !covers.isEmpty else { return files }

        let coversByFolder = Dictionary(grouping: covers, by: { torBoxPathKey($0.parentFolder) })
            .mapValues { covers in
                covers.sorted {
                    if $0.rank != $1.rank { return $0.rank < $1.rank }
                    return $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }.first
            }

        return files.map { file in
            let cover = firstNotNil(folderAndAncestors(file.parentFolder)) { coversByFolder[torBoxPathKey($0)] ?? nil }
            return TorBoxCloudFile(
                id: file.id,
                name: file.name,
                path: file.path,
                parentFolder: file.parentFolder,
                link: file.link,
                size: file.size,
                cover: cover
            )
        }
    }

    private func firstNotNil<T, U>(_ values: [T], transform: (T) -> U?) -> U? {
        for value in values {
            if let transformed = transform(value) {
                return transformed
            }
        }
        return nil
    }

    private func filterTorBoxFiles(_ files: [TorBoxCloudFile], rootPath: String) -> [TorBoxCloudFile] {
        let root = torBoxPathKey(rootPath)
        guard !root.isEmpty else { return files }

        return files.filter { file in
            let path = torBoxPathKey(file.path)
            let parent = torBoxPathKey(file.parentFolder)
            return path == root || path.hasPrefix(root + "/") || parent == root || parent.hasPrefix(root + "/")
        }
    }

    private func fetchTorBoxJSONArray(url: URL, token: String, key: String) async -> [[String: Any]] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return [] }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
            return object[key] as? [[String: Any]] ?? []
        } catch {
            AppLogger.network.error(
                "TorBox API scan failed endpointDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: url.path)): \(error.localizedDescription)"
            )
            return []
        }
    }

    private func torBoxAPIURL(pathSegments: [String], queryItems: [URLQueryItem]) -> URL? {
        let base =
            connection.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "https://api.torbox.app/v1/api"
            : connection.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: base) else { return nil }
        var path = components.path
        for segment in pathSegments {
            path += "/" + segment
        }
        components.path = path.replacingOccurrences(of: "//", with: "/")
        components.queryItems = queryItems
        return components.url
    }

    private func torBoxRequestDownloadURL(token: String, typePath: String, idParameter: String, itemId: String, fileId: String) -> URL? {
        torBoxAPIURL(
            pathSegments: [typePath, "requestdl"],
            queryItems: [
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: idParameter, value: itemId),
                URLQueryItem(name: "file_id", value: fileId),
                URLQueryItem(name: "redirect", value: "true"),
            ]
        )
    }

    private func torBoxDisplayPath(file: [String: Any], itemName: String) -> String? {
        let name = stringValue(file["name"])
        let shortName = stringValue(file["short_name"])
        let explicitPath = stringValue(file["path"])
        let s3Path = stringValue(file["s3_path"])

        return [
            explicitPath,
            name?.contains("/") == true ? name : nil,
            shortName.flatMap { leaf in
                name.flatMap { fullName in
                    fullName.isEmpty || fullName == leaf ? nil : "\(fullName)/\(leaf)"
                }
            },
            shortName.map { "\(itemName)/\($0)" },
            name,
            s3Path,
        ]
        .compactMap { $0?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        .first { !$0.isEmpty }
        .map(decodeTorBoxPath)
    }

    private func torBoxParentPath(for path: String, fallback: String) -> String {
        let parent = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .components(separatedBy: "/")
            .dropLast()
            .joined(separator: "/")
        return parent.isEmpty ? fallback : parent
    }

    private func torBoxPathKey(_ path: String) -> String {
        path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }

    private func decodeTorBoxPath(_ path: String) -> String {
        path.components(separatedBy: "/")
            .map(decodeTorBoxPathSegment)
            .joined(separator: "/")
    }

    private func decodeTorBoxPathSegment(_ segment: String) -> String {
        segment.replacingOccurrences(of: "+", with: "%2B").removingPercentEncoding ?? segment
    }

    private func isTorBoxAudioFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp3", "m4b", "m4a", "mp4", "aac", "flac", "ogg", "opus", "wav"].contains(ext)
    }

    private func isTorBoxCoverFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["jpg", "jpeg", "png", "webp"].contains(ext)
    }

    private func torBoxCoverRank(_ name: String) -> Int {
        let stem = ((name as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        if ["cover", "folder", "front", "album", "artwork"].contains(stem) { return 0 }
        if stem.contains("cover") || stem.contains("folder") || stem.contains("front") { return 1 }
        return 10
    }

    private func folderAndAncestors(_ path: String) -> [String] {
        let parts = path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return [] }
        return parts.indices.reversed().map { parts.prefix($0 + 1).joined(separator: "/") }
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "1", "yes"].contains(string.lowercased()) }
        return nil
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }

    private func scanEbookFiles(server: WebDAVServerConfig, rootPath: String) async throws -> [WebDAVEbookFile] {
        let collector = BookFolderCollector()
        let maxConcurrency = 4
        var queue: [String] = [normalizedServerPath(rootPath)]
        var ebooks: [WebDAVEbookFile] = []
        var batchCount = 0

        while !queue.isEmpty {
            let batch = Array(queue.prefix(maxConcurrency))
            queue.removeFirst(min(maxConcurrency, queue.count))

            batchCount += 1
            if batchCount > 1 {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }

            await withTaskGroup(of: (String, [RemoteFileEntry])?.self) { group in
                for path in batch {
                    let normalizedPath = normalizedServerPath(path)
                    guard await collector.markVisited(normalizedPath) else { continue }

                    group.addTask {
                        do {
                            let entries = try await RemoteImportService.shared.listWebDAVDirectory(server: server, path: normalizedPath)
                            return (normalizedPath, entries)
                        } catch {
                            AppLogger.network.error("ebook scan skipping '\(normalizedPath)': \(error.localizedDescription)")
                            return nil
                        }
                    }
                }

                for await result in group {
                    guard let (dirPath, entries) = result else { continue }

                    let ebookEntries = entries.filter { $0.isEbookFile }
                    for ebookEntry in ebookEntries {
                        ebooks.append(WebDAVEbookFile(entry: ebookEntry, folderPath: dirPath, folderEntries: entries))
                    }

                    let subdirs = entries.filter { $0.isDirectory }
                    for subdir in subdirs {
                        let childPath = normalizedServerPath(subdir.path)
                        if childPath != dirPath {
                            queue.append(childPath)
                        }
                    }
                }
            }
        }

        if !ebooks.isEmpty {
            AppLogger.network.info("scanEbookFiles found \(ebooks.count) ebook files (\(batchCount) batches)")
        }

        return ebooks
    }

    private func webDAVData(for url: URL, server: WebDAVServerConfig) async throws -> (Data, URLResponse) {
        let request = URLRequest(url: url)
        let username = server.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = (server.password ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let session: URLSession
        var challengeDelegate: ProviderWebDAVAuthDelegate?

        if !username.isEmpty {
            challengeDelegate = ProviderWebDAVAuthDelegate(username: username, password: password)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 300
            session = URLSession(configuration: config, delegate: challengeDelegate, delegateQueue: nil)
        } else {
            session = URLSession.shared
        }

        do {
            let result = try await session.data(for: request)
            if challengeDelegate != nil { session.finishTasksAndInvalidate() }
            return result
        } catch {
            if challengeDelegate != nil { session.finishTasksAndInvalidate() }
            throw error
        }
    }

    private struct FolderPathMetadata {
        var author: String?
        var series: String?
        var seriesNumber: Int?
        var title: String?
        var publishedYear: Int?
    }

    private func parseMetadataFromPath(_ bookPath: String, rootPath: String) -> FolderPathMetadata {
        let normalizedBook = normalizedServerPath(bookPath)
        let normalizedRoot = normalizedServerPath(rootPath)

        var relativePath = normalizedBook
        if relativePath.hasPrefix(normalizedRoot) {
            relativePath = String(relativePath.dropFirst(normalizedRoot.count))
        }
        if relativePath.hasPrefix("/") {
            relativePath = String(relativePath.dropFirst())
        }

        let components = relativePath.split(separator: "/").map(String.init)

        guard !components.isEmpty else { return FolderPathMetadata() }

        var meta = FolderPathMetadata()

        guard let bookFolder = components.last else { return FolderPathMetadata() }
        let (title, number) = extractSeriesNumber(from: bookFolder)
        let (cleanedTitle, year) = extractYear(from: title)
        meta.title = cleanedTitle
        meta.seriesNumber = number
        meta.publishedYear = year

        switch components.count {
        case 1:
            break
        case 2:
            meta.author = String(components[0])
        case 3:
            meta.author = String(components[0])
            meta.series = String(components[1])
        default:
            meta.author = String(components[0])
            meta.series = String(components[1])
        }

        return meta
    }

    private func extractSeriesNumber(from folderName: String) -> (title: String, number: Int?) {
        let dashPattern = #"^(\d+)\s*[-\x{2013}.]\s*(.+)$"#
        if let match = folderName.range(of: dashPattern, options: .regularExpression),
            let numberRange = folderName.range(of: #"^\d+"#, options: .regularExpression)
        {
            let number = Int(folderName[numberRange])
            let rest = String(folderName[match]).replacingOccurrences(of: #"^\d+\s*[-\x{2013}.]\s*"#, with: "", options: .regularExpression)
            return (rest.trimmingCharacters(in: .whitespaces), number)
        }
        let hashPattern = #"^#(\d+)\s*[-\x{2013}.]?\s*(.*)$"#
        if let numberRange = folderName.range(of: #"(?<=^#)\d+"#, options: .regularExpression) {
            let number = Int(folderName[numberRange])
            let rest = folderName.replacingOccurrences(of: hashPattern, with: "$2", options: .regularExpression)
            let title = rest.trimmingCharacters(in: .whitespaces)
            return (title.isEmpty ? folderName : title, number)
        }
        let bookNumPattern = #"^(.+?)\s+(?:Book|Vol\.?|Volume)\s*(\d+)$"#
        if folderName.range(of: bookNumPattern, options: [.regularExpression, .caseInsensitive]) != nil {
            guard let numRange = folderName.range(of: #"\d+$"#, options: .regularExpression) else {
                return (folderName, nil)
            }
            let number = Int(folderName[numRange])
            let title = folderName.replacingOccurrences(of: bookNumPattern, with: "$1", options: [.regularExpression, .caseInsensitive])
            return (title.trimmingCharacters(in: .whitespaces), number)
        }
        return (folderName, nil)
    }

    private func extractYear(from title: String) -> (title: String, year: Int?) {
        let pattern = #"\s*\{(\d{4})\}\s*$"#
        guard title.range(of: pattern, options: .regularExpression) != nil else {
            return (title, nil)
        }
        let yearStr = title.replacingOccurrences(of: #".*\{(\d{4})\}.*"#, with: "$1", options: .regularExpression)
        let cleanTitle = title.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return (cleanTitle, Int(yearStr))
    }

    private func buildPlaybackSession(for book: Book) async throws -> PlaybackSessionInfo {
        var tracks = book.audioTracks ?? []

        if tracks.isEmpty {
            let server = try await resolveServerConfig()
            if let filePath = book.filePath, AudiobookFormat.from(fileExtension: (filePath as NSString).pathExtension.lowercased()) != nil {
                let contentUrl = server.url(for: filePath).absoluteString
                tracks = [
                    AudioTrack(
                        index: 0,
                        filePath: filePath,
                        contentUrl: contentUrl,
                        duration: 0,
                        startOffset: 0,
                        headers: getStreamingHeaders()
                    )
                ]
            } else {
                let refetched = try await fetchBooks(libraryId: book.libraryId)
                if let match = refetched.first(where: { $0.id == book.id }), let refetchedTracks = match.audioTracks,
                    !refetchedTracks.isEmpty
                {
                    tracks = refetchedTracks
                } else {
                    throw ProviderError.invalidResponse
                }
            }
        }

        var audioInfos: [AudioTrackInfo] = []
        var startOffset: Double = 0

        for (index, track) in tracks.enumerated() {
            guard let contentUrl = track.contentUrl else { continue }
            let url = URL(string: contentUrl)
            var duration = track.duration

            if duration <= 0, let url, NetworkPolicyService.shared.isConnected {
                duration = await resolveDuration(for: url)
            }

            audioInfos.append(
                AudioTrackInfo(
                    index: index,
                    startOffset: startOffset,
                    duration: duration,
                    contentUrl: contentUrl,
                    mimeType: mimeType(for: contentUrl)
                )
            )
            startOffset += duration
        }

        let chapters = makeChapters(from: audioInfos, fallbackTitles: tracks.map { $0.title })
        let sessionId = "webdav:\(book.id)"

        return PlaybackSessionInfo(sessionId: sessionId, audioTracks: audioInfos, chapters: chapters)
    }

    private func resolveDuration(for url: URL) async -> Double {
        let headers = getStreamingHeaders()
        let options = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
        do {
            let duration = try await asset.load(.duration)
            let seconds = duration.seconds
            return seconds.isFinite ? seconds : 0
        } catch {
            return 0
        }
    }

    private func makeChapters(from tracks: [AudioTrackInfo], fallbackTitles: [String?]) -> [Chapter] {
        guard !tracks.isEmpty else { return [] }
        var chapters: [Chapter] = []

        for (index, track) in tracks.enumerated() {
            let title = fallbackTitles.indices.contains(index) ? (fallbackTitles[index] ?? "Track \(index + 1)") : "Track \(index + 1)"
            let chapter = Chapter(
                id: "webdav-chapter-\(index)",
                start: track.startOffset,
                end: track.startOffset + track.duration,
                title: title,
                index: index
            )
            chapters.append(chapter)
        }

        return chapters
    }

    private func mimeType(for urlString: String) -> String {
        let ext = (urlString as NSString).pathExtension.lowercased()
        switch ext {
        case "m4b", "m4a", "mp4": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "ogg": return "audio/ogg"
        default: return "audio/mpeg"
        }
    }

    private func extractChaptersFromAudioFile(streamURL: URL, bookDuration: Double) async throws -> [Chapter] {
        let cacheKey = "enve.webdav.chapterCache.\(streamURL.absoluteString.hashValue)"
        let cacheDateKey = cacheKey + ".date"
        if let cachedData = UserDefaults.standard.data(forKey: cacheKey),
            let cachedDate = UserDefaults.standard.object(forKey: cacheDateKey) as? Date,
            Date().timeIntervalSince(cachedDate) < 604_800,
            let cached = try? JSONDecoder().decode([Chapter].self, from: cachedData), !cached.isEmpty
        {
            AppLogger.network.debug(
                "[WebDAV] Chapter cache hit streamDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: streamURL.path))"
            )
            return cached
        }

        let headers = getStreamingHeaders()
        if let rangedChapters = await RemoteMP4ChapterExtractor.extractChapters(
            from: streamURL,
            headers: headers,
            durationHint: bookDuration > 0 ? bookDuration : nil
        ), !rangedChapters.isEmpty {
            if let encoded = try? JSONEncoder().encode(rangedChapters) {
                UserDefaults.standard.set(encoded, forKey: cacheKey)
                UserDefaults.standard.set(Date(), forKey: cacheDateKey)
            }
            return rangedChapters
        }

        let options = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: streamURL, options: options)

        let startTime = Date()
        let chapterLocales = try await asset.load(.availableChapterLocales)

        guard Date().timeIntervalSince(startTime) < 10 else {
            throw NSError(
                domain: "ChapterExtraction",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Timeout loading chapter locales"]
            )
        }

        var extractedChapters: [Chapter] = []

        for locale in chapterLocales {
            let chapterGroups = try await asset.loadChapterMetadataGroups(
                withTitleLocale: locale,
                containingItemsWithCommonKeys: [.commonKeyArtwork]
            )

            for (index, group) in chapterGroups.enumerated() {
                let chapterStartTime = CMTimeGetSeconds(group.timeRange.start)
                let duration = CMTimeGetSeconds(group.timeRange.duration)
                let chapterEndTime = chapterStartTime + duration

                var title = "Chapter \(index + 1)"
                if let titleItem = group.items.first(where: { $0.commonKey == .commonKeyTitle }),
                    let titleValue = try? await titleItem.load(.value) as? String
                {
                    title = titleValue
                }

                let chapter = Chapter(
                    id: String(index),
                    start: chapterStartTime,
                    end: chapterEndTime,
                    title: title,
                    index: index
                )
                extractedChapters.append(chapter)
            }

            if !extractedChapters.isEmpty {
                break
            }
        }

        if !extractedChapters.isEmpty,
            let encoded = try? JSONEncoder().encode(extractedChapters)
        {
            UserDefaults.standard.set(encoded, forKey: cacheKey)
            UserDefaults.standard.set(Date(), forKey: cacheDateKey)
        }

        return extractedChapters
    }

    private func prefetchChaptersAndDurations(
        for books: [Book],
        server: WebDAVServerConfig,
        libraryId: String,
        libraryName: String,
        reportProgress: Bool = true
    ) async {
        let needsPrefetch = books.filter { book in
            let missingChapters = book.chapters == nil || book.chapters?.isEmpty == true
            let missingDuration = book.duration == nil || book.duration == 0
            return missingChapters || missingDuration
        }

        guard !needsPrefetch.isEmpty else {
            AppLogger.network.warning("All \(books.count) books already have chapters/durations - skipping prefetch")
            return
        }

        AppLogger.network.info("Background prefetching chapters/durations for \(needsPrefetch.count) books...")

        if reportProgress {
            await MainActor.run {
                AppState.shared.presentation.libraryImportProgress = LibraryImportProgress(
                    libraryId: libraryId,
                    libraryName: libraryName,
                    loadedCount: 0,
                    totalCount: needsPrefetch.count,
                    isComplete: false,
                    phase: .enrichingMetadata
                )
            }
        }

        var processed = 0

        for book in needsPrefetch {
            do {
                let session = try await buildPlaybackSession(for: book)
                var chapters: [Chapter] = session.chapters
                let totalDuration = session.audioTracks.reduce(0.0) { $0 + $1.duration }

                if let audioTracks = book.audioTracks, audioTracks.count == 1,
                    let firstTrack = audioTracks.first,
                    let contentUrl = firstTrack.contentUrl,
                    let audioURL = URL(string: contentUrl)
                {
                    if let embedded = try? await extractChaptersFromAudioFile(
                        streamURL: audioURL,
                        bookDuration: totalDuration
                    ), !embedded.isEmpty {
                        chapters = embedded
                    }
                }

                let finalChapters = chapters
                let finalDuration = totalDuration
                if !finalChapters.isEmpty {
                    try? await MetadataStorage.shared.updateLayer(bookId: book.id, layer: .appCache) { metadata in
                        var backend =
                            metadata.backend
                            ?? BackendMetadataLayer(
                                title: book.title,
                                author: book.author,
                                narrator: book.narrator,
                                series: book.series,
                                seriesNumber: book.seriesNumber,
                                year: book.publishedYear,
                                publisher: book.publisher,
                                genres: book.genres,
                                description: book.description,
                                duration: finalDuration > 0 ? finalDuration : book.duration,
                                isbn: book.isbn,
                                asin: book.asin,
                                fileName: nil,
                                folderName: nil,
                                chapters: finalChapters,
                                thumb: book.thumb
                            )
                        backend.chapters = finalChapters
                        if finalDuration > 0 { backend.duration = finalDuration }
                        metadata.backend = backend
                    }
                }

                await MainActor.run { () -> Void in
                    _ = AppState.shared.mutateBook(uniqueId: book.uniqueId) { updated in
                        let isMultiTrack = (updated.audioTracks?.count ?? 0) > 1
                        if !finalChapters.isEmpty && (updated.chapters == nil || updated.chapters?.isEmpty == true) {
                            updated.chapters = finalChapters
                        }
                        if shouldUseAggregatedDuration(
                            currentDuration: updated.duration,
                            aggregatedDuration: finalDuration,
                            isMultiTrack: isMultiTrack
                        ) {
                            updated.duration = finalDuration
                        }
                    }
                }
            } catch {
                AppLogger.network.error(
                    "Prefetch failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
                )
            }

            processed += 1
            if reportProgress && (processed % 5 == 0 || processed == needsPrefetch.count) {
                await MainActor.run {
                    AppState.shared.presentation.libraryImportProgress = LibraryImportProgress(
                        libraryId: libraryId,
                        libraryName: libraryName,
                        loadedCount: processed,
                        totalCount: needsPrefetch.count,
                        isComplete: processed == needsPrefetch.count,
                        phase: .enrichingMetadata
                    )
                }
            }

            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        AppLogger.network.info("Background prefetch complete: \(processed)/\(needsPrefetch.count) books")

        if reportProgress {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                AppState.shared.presentation.libraryImportProgress = nil
            }
        }
    }

    private func isPremiumizeConnection() -> Bool {
        if connection.type == .premiumize {
            return true
        }

        guard let host = URL(string: connection.url)?.host?.lowercased() else {
            return false
        }
        return host.contains("premiumize")
    }

    private func enrichBooksWithMetadata(books: [Book], server: WebDAVServerConfig, libraryId: String, libraryName: String) async {
        let booksNeedingEnrichment = books.filter { book in
            let needsCover = book.thumb == nil
            let needsMetadata = book.author == nil || book.duration == nil || book.duration == 0
            return needsCover || needsMetadata
        }

        let totalBooks = booksNeedingEnrichment.count

        if totalBooks == 0 {
            AppLogger.network.warning("All books already have complete metadata, skipping enrichment")
            return
        }

        AppLogger.network.info("Starting metadata enrichment for \(totalBooks) books (out of \(books.count) total)")

        await MainActor.run {
            AppState.shared.presentation.libraryImportProgress = LibraryImportProgress(
                libraryId: libraryId,
                libraryName: libraryName,
                loadedCount: 0,
                totalCount: totalBooks,
                isComplete: false,
                phase: .enrichingMetadata
            )
        }

        var processedCount = 0

        for book in booksNeedingEnrichment {
            try? await Task.sleep(nanoseconds: 300_000_000)

            var updatedBook = book
            var needsUpdate = false

            if book.thumb == nil,
                let firstTrack = book.audioTracks?.first,
                let contentUrl = firstTrack.contentUrl,
                let audioURL = URL(string: contentUrl)
            {

                do {
                    let coverData = try await extractCoverArt(from: audioURL, server: server)
                    if let cachedURL = saveCoverToCache(data: coverData, bookId: book.id) {
                        updatedBook.thumb = cachedURL.absoluteString
                        await persistExtractedCover(cachedURL, for: updatedBook)
                        needsUpdate = true
                        AppLogger.network.debug(
                            "Extracted cover bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                        )
                    }
                } catch {
                    AppLogger.network.debug(
                        "WebDAV cover extraction failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
                    )
                }
            }

            if book.author == nil || book.duration == nil || book.duration == 0 {
                if let firstTrack = book.audioTracks?.first,
                    let contentUrl = firstTrack.contentUrl,
                    let audioURL = URL(string: contentUrl)
                {

                    if let embedded = try? await FileMetadataExtractor.shared.extractMetadataFromRemoteStream(
                        streamURL: audioURL,
                        headers: streamingHeaders(for: server),
                        timeout: 10.0
                    ) {
                        let meta = localBookMetadata(from: embedded, fallbackTitle: book.title)

                        let isMultiTrack = (updatedBook.audioTracks?.count ?? 0) > 1
                        let resolvedDuration: TimeInterval?
                        if isMultiTrack {
                            resolvedDuration = updatedBook.duration
                        } else {
                            resolvedDuration = meta.duration ?? updatedBook.duration
                        }

                        updatedBook = Book(
                            id: updatedBook.id,
                            ratingKey: updatedBook.ratingKey,
                            title: meta.title,
                            author: meta.author ?? updatedBook.author,
                            narrator: meta.narrator ?? updatedBook.narrator,
                            thumb: updatedBook.thumb,
                            partKey: updatedBook.partKey,
                            duration: resolvedDuration,
                            chapters: updatedBook.chapters,
                            currentChapterIndex: updatedBook.currentChapterIndex,
                            source: updatedBook.source,
                            backendId: updatedBook.backendId,
                            trackIndex: updatedBook.trackIndex,
                            filePath: updatedBook.filePath,
                            audioFileIno: updatedBook.audioFileIno,
                            audioFileInos: updatedBook.audioFileInos,
                            audioTracks: updatedBook.audioTracks,
                            description: meta.description ?? updatedBook.description,
                            series: meta.series ?? updatedBook.series,
                            seriesNumber: meta.seriesNumber ?? updatedBook.seriesNumber,
                            publishedYear: meta.publishedYear ?? updatedBook.publishedYear,
                            genres: meta.genres ?? updatedBook.genres,
                            publisher: updatedBook.publisher,
                            isbn: meta.isbn ?? updatedBook.isbn,
                            asin: meta.asin ?? updatedBook.asin,
                            addedAt: updatedBook.addedAt,
                            libraryName: updatedBook.libraryName,
                            backendName: updatedBook.backendName,
                            currentTime: updatedBook.currentTime,
                            isFinished: updatedBook.isFinished,
                            lastUpdate: updatedBook.lastUpdate,
                            providerId: updatedBook.providerId,
                            libraryId: updatedBook.libraryId
                        )
                        needsUpdate = true
                        AppLogger.network.debug(
                            "Extracted metadata bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                        )
                    }
                }
            }

            if needsUpdate {
                await MainActor.run { () -> Void in
                    _ = AppState.shared.mutateBook(uniqueId: book.uniqueId) { $0 = updatedBook }
                }
            }

            processedCount += 1

            await MainActor.run {
                AppState.shared.presentation.libraryImportProgress = LibraryImportProgress(
                    libraryId: libraryId,
                    libraryName: libraryName,
                    loadedCount: processedCount,
                    totalCount: totalBooks,
                    isComplete: false,
                    phase: .enrichingMetadata
                )
            }
        }

        await MainActor.run {
            AppState.shared.presentation.libraryImportProgress = LibraryImportProgress(
                libraryId: libraryId,
                libraryName: libraryName,
                loadedCount: processedCount,
                totalCount: totalBooks,
                isComplete: true,
                phase: .enrichingMetadata
            )
        }

        AppLogger.network.info("Metadata enrichment complete: \(processedCount)/\(totalBooks) books")

        try? await Task.sleep(nanoseconds: 3_000_000_000)
        await MainActor.run {
            AppState.shared.presentation.libraryImportProgress = nil
        }
    }

    private func extractMissingCovers(for books: [Book], server: WebDAVServerConfig, libraryId: String) async {
        AppLogger.network.info(
            "[WebDAV] Starting background cover extraction for \(books.filter { $0.thumb == nil }.count) books without covers"
        )

        for book in books where book.thumb == nil {
            try? await Task.sleep(nanoseconds: 500_000_000)

            guard let firstTrack = book.audioTracks?.first,
                let contentUrl = firstTrack.contentUrl,
                let audioURL = URL(string: contentUrl)
            else {
                continue
            }

            do {
                let coverData = try await extractCoverArt(from: audioURL, server: server)
                var shouldPersistBooksCache = false

                await MainActor.run {
                    if let cachedURL = saveCoverToCache(data: coverData, bookId: book.id) {
                        let mutated = AppState.shared.mutateBook(uniqueId: book.uniqueId) {
                            $0.thumb = cachedURL.absoluteString
                        }
                        if mutated != nil {
                            shouldPersistBooksCache = true
                            AppLogger.network.debug(
                                "Cached extracted cover bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId))"
                            )
                        }
                    }
                }

                if let updatedBook = await MainActor.run(body: {
                    AppState.shared.bookInMemory(uniqueId: book.uniqueId)
                }), let cachedURL = updatedBook.coverURL {
                    await persistExtractedCover(cachedURL, for: updatedBook)
                }

                _ = shouldPersistBooksCache
            } catch {
                AppLogger.network.error(
                    "Cover extraction failed bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: book.stableId)): \(error.localizedDescription)"
                )
            }
        }

        AppLogger.network.info("[WebDAV] Background cover extraction complete")
    }

    private func extractCoverArt(from url: URL, server: WebDAVServerConfig) async throws -> Data {
        let headers = streamingHeaders(for: server)
        let options = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)

        let artworkItems = try await asset.load(.commonMetadata).filter { $0.commonKey == .commonKeyArtwork }

        guard let artworkItem = artworkItems.first,
            let imageData = try await artworkItem.load(.value) as? Data
        else {
            throw NSError(domain: "CoverExtraction", code: -1, userInfo: [NSLocalizedDescriptionKey: "No artwork found"])
        }

        return imageData
    }

    private func saveCoverToCache(data: Data, bookId: String) -> URL? {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Covers", isDirectory: true)

        guard let cacheDir = cacheDir else { return nil }

        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let fileName = "\(bookId.replacingOccurrences(of: ":", with: "_")).jpg"
        let fileURL = cacheDir.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            AppLogger.network.error("Failed to save cover to cache: \(error)")
            return nil
        }
    }

    private func persistExtractedCover(_ cachedURL: URL, for book: Book) async {
        try? await MetadataStorage.shared.updateLayer(bookId: book.id, layer: .file) { metadata in
            metadata.file.coverPath = cachedURL.path
        }
        NotificationCenter.default.post(name: .metadataUpdated, object: book.id)
    }

    private func shouldUseAggregatedDuration(
        currentDuration: TimeInterval?,
        aggregatedDuration: TimeInterval,
        isMultiTrack: Bool
    ) -> Bool {
        guard aggregatedDuration > 0 else { return false }
        guard let current = currentDuration, current > 0 else { return true }
        guard isMultiTrack else { return false }

        return current + 1.0 < aggregatedDuration
    }
}

private actor BookFolderCollector {
    private var folders: [WebDAVBookFolder] = []
    private var visited: Set<String> = []

    func markVisited(_ path: String) -> Bool {
        if visited.contains(path) { return false }
        visited.insert(path)
        return true
    }

    func addFolder(_ folder: WebDAVBookFolder) {
        folders.append(folder)
    }

    var results: [WebDAVBookFolder] {
        folders
    }
}

private final class ProviderWebDAVAuthDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let credential: URLCredential
    private var challengeCount = 0

    init(username: String, password: String) {
        self.credential = URLCredential(
            user: username,
            password: password,
            persistence: .forSession
        )
        super.init()
    }

    @objc nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        let host = challenge.protectionSpace.host

        if method == NSURLAuthenticationMethodClientCertificate {
            if let identity = NetworkHostUtils.findMTLSIdentity(forHost: host) {
                completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
            return
        }

        if (method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest) && challengeCount < 2 {
            challengeCount += 1
            completionHandler(.useCredential, credential)
        } else if method == NSURLAuthenticationMethodServerTrust {
            if let trust = challenge.protectionSpace.serverTrust,
                NetworkHostUtils.isLocalNetworkHost(host)
            {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

struct WebDAVBookFolder {
    let path: String
    let audioFiles: [RemoteFileEntry]
    let entries: [RemoteFileEntry]
    let coverURL: String?

    init(path: String, audioFiles: [RemoteFileEntry], entries: [RemoteFileEntry], coverURL: String? = nil) {
        self.path = path
        self.audioFiles = audioFiles
        self.entries = entries
        self.coverURL = coverURL
    }
}

private struct AudiobookshelfMetadata: Codable {
    let title: String?
    let author: String?
    let narrator: String?
    let description: String?
    let series: String?
    let seriesSequence: String?
    let publishedYear: Int?
    let genres: [String]?
    let duration: Double?
    let chapters: [AudiobookshelfChapter]?

    struct AudiobookshelfChapter: Codable {
        let title: String
        let start: Double
        let end: Double
    }

    func toLocalBookMetadata() -> LocalBookMetadata {
        let localChapters: [LocalChapter]? = chapters?.map { chapter in
            LocalChapter(
                title: chapter.title,
                startTime: chapter.start,
                endTime: chapter.end,
                duration: chapter.end - chapter.start
            )
        }

        return LocalBookMetadata(
            title: title ?? "Unknown",
            author: author,
            narrator: narrator,
            description: description,
            series: series,
            seriesNumber: Int(seriesSequence ?? ""),
            seriesSequence: seriesSequence,
            publishedYear: publishedYear,
            genres: genres,
            duration: duration,
            chapters: localChapters
        )
    }
}

private struct GenericBookMetadata: Codable {
    let title: String?
    let author: String?
    let authors: [String]?
    let narrator: String?
    let narrators: [String]?
    let description: String?
    let summary: String?
    let series: String?
    let seriesIndex: Int?
    let year: Int?
    let publishedYear: Int?
    let genres: [String]?
    let tags: [String]?
    let duration: Double?
    let durationMs: Int?

    func toLocalBookMetadata() -> LocalBookMetadata {
        let authorStr = author ?? authors?.joined(separator: ", ")
        let narratorStr = narrator ?? narrators?.joined(separator: ", ")
        let desc = description ?? summary
        let pubYear = publishedYear ?? year
        let dur: TimeInterval? =
            if let d = duration {
                d
            } else if let ms = durationMs {
                Double(ms) / 1000.0
            } else {
                nil
            }

        return LocalBookMetadata(
            title: title ?? "Unknown",
            author: authorStr,
            narrator: narratorStr,
            description: desc,
            series: series,
            seriesNumber: seriesIndex,
            publishedYear: pubYear,
            genres: genres ?? tags,
            duration: dur
        )
    }
}
