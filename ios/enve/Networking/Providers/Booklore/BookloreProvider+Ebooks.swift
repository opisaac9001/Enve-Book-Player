import Foundation
import Logging

extension BookloreProvider {
    func fetchFullBookDetails(bookId: String, libraryId: String) async throws -> Book {

        let isCompanionAudiobook = bookId.hasPrefix(Self.companionAudiobookIDPrefix)
        let bookId =
            isCompanionAudiobook
            ? String(bookId.dropFirst(Self.companionAudiobookIDPrefix.count))
            : bookId

        func finalize(_ base: Book) async -> Book {
            var resolved = isCompanionAudiobook ? makeCompanionAudiobook(forEbook: base) : base
            if !isCompanionAudiobook, resolved.hasAlternateFormat {
                resolved.linkedAudiobookStableId = makeCompanionAudiobook(forEbook: base).stableId
                resolved.hasAlternateFormat = false
            }
            if resolved.mediaType == .ebook,
                resolved.epub3Features == nil,
                let features = await fetchEPUB3Features(bookId: bookId)
            {
                resolved.epub3Features = features
            }
            return await enrichAudiobookIfNeeded(resolved)
        }

        if useLegacyRestAPI {
            let request = try makeRequest(path: "/api/v1/libraries/\(libraryId)/book/\(bookId)")
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else {
                throw ProviderError.serverError("Failed to fetch book (HTTP \(response.statusCode))")
            }
            let book = try JSONDecoder().decode(BookloreLegacyBook.self, from: data)
            return await finalize(BookloreCatalogMapper.book(from: book, context: catalogMapperContext(libraryId: libraryId)))
        }
        if useKomgaFallback {
            let request = try makeKomgaBasicRequest(path: "/komga/api/v1/books/\(bookId)")
            let (data, response) = try await send(request)
            guard response.statusCode == 200 else {
                throw ProviderError.serverError("Failed to fetch book (HTTP \(response.statusCode))")
            }
            let book = try JSONDecoder().decode(KomgaBook.self, from: data)
            return await finalize(mapKomgaBookToBook(book, libraryId: libraryId))
        }

        func fetchAppStyleDetail(path: String) async throws -> BookloreBookDetail {
            let request = try makeRequest(path: path)
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else {
                throw ProviderError.serverError("Failed to fetch book details (HTTP \(response.statusCode))")
            }
            try guardJSON(data, response: response, endpoint: path)
            return try JSONDecoder().decode(BookloreBookDetail.self, from: data)
        }

        if let detail = try? await fetchAppStyleDetail(path: "/api/v1/app/books/\(bookId)") {
            return await finalize(mapToBook(detail, fallbackLibraryId: libraryId))
        }

        if let detail = try? await fetchAppStyleDetail(path: "/api/v1/books/\(bookId)") {
            return await finalize(mapToBook(detail, fallbackLibraryId: libraryId))
        }

        AppLogger.network.info("[Booklore] Full book details app endpoints unavailable - falling back to legacy detail endpoint")
        let request = try makeRequest(path: "/api/v1/libraries/\(libraryId)/book/\(bookId)")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch book (HTTP \(response.statusCode))")
        }
        let book = try JSONDecoder().decode(BookloreLegacyBook.self, from: data)
        return await finalize(BookloreCatalogMapper.book(from: book, context: catalogMapperContext(libraryId: libraryId)))
    }

    func fetchComicReadingDirection(for book: Book) async throws -> ComicReadingDirection? {
        guard !useLegacyRestAPI, !useKomgaFallback else { return nil }
        let path = "/api/v1/books/\(book.id)"
        let (data, response) = try await performAuthorizedRequest(makeRequest(path: path))
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to fetch comic metadata (HTTP \(response.statusCode))")
        }
        try guardJSON(data, response: response, endpoint: path)
        struct Detail: Decodable {
            struct Metadata: Decodable {
                struct Comic: Decodable {
                    let readingDirection: String?
                }
                let comicMetadata: Comic?
            }
            let metadata: Metadata?
        }
        let detail = try JSONDecoder().decode(Detail.self, from: data)
        switch detail.metadata?.comicMetadata?.readingDirection?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rtl": return .rightToLeft
        case "ltr": return .leftToRight
        default: return nil
        }
    }

    func fetchEPUB3Features(bookId: String) async -> EPUB3Features? {
        guard !useKomgaFallback else { return nil }
        let bookId =
            bookId.hasPrefix(Self.companionAudiobookIDPrefix)
            ? String(bookId.dropFirst(Self.companionAudiobookIDPrefix.count))
            : bookId

        struct EpubInfo: Decodable {
            struct Item: Decodable {
                let href: String?
                let mediaType: String?
            }
            let manifest: [Item]?
            let metadata: [String: String]?
        }

        do {
            let request = try makeRequest(path: "/api/v1/epub/\(bookId)/info")
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else { return nil }
            let info = try JSONDecoder().decode(EpubInfo.self, from: data)

            let smilCount = (info.manifest ?? []).filter { item in
                item.mediaType?.localizedCaseInsensitiveContains("smil") == true
                    || item.href?.lowercased().hasSuffix(".smil") == true
            }.count
            guard smilCount > 0 || info.metadata?["media:duration"] != nil else { return nil }

            return EPUB3Features(hasMediaOverlay: true, hasFixedLayout: false, smilFileCount: smilCount)
        } catch {
            return nil
        }
    }

    private struct GrimmoryEpubStreamInfo: Decodable {
        struct ManifestItem: Decodable {
            let href: String?
            let mediaType: String?
            let size: Int64?
        }
        let containerPath: String?
        let manifest: [ManifestItem]?
    }

    func makeEpubStreamingSession(for book: Book) async throws -> GrimmoryEpubStreamingSession {
        guard !useKomgaFallback, !useLegacyRestAPI else {
            throw ProviderError.notImplemented
        }
        guard let bookId = resolveGrimmoryBookId(for: book) else {
            throw ProviderError.invalidResponse
        }
        let resource = try await resolveGrimmoryEbookResource(for: book)
        let queryItems =
            (resource?.isPrimary ?? true)
            ? []
            : [URLQueryItem(name: "bookType", value: "EPUB")]

        let request = try makeRequest(path: "/api/v1/epub/\(bookId)/info", queryItems: queryItems)
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Grimmory EPUB streaming unavailable (HTTP \(response.statusCode))")
        }
        let info = try JSONDecoder().decode(GrimmoryEpubStreamInfo.self, from: data)

        var entries: [GrimmoryEpubStreamingSession.Entry] = []
        var seen = Set<String>()
        func addEntry(_ path: String?, mediaType: String?, size: Int64?) {
            guard let path, !path.isEmpty, !path.contains(".."), seen.insert(path).inserted else { return }
            entries.append(.init(path: path, mediaType: mediaType, size: UInt64(max(size ?? 0, 0))))
        }
        addEntry("META-INF/container.xml", mediaType: "application/xml", size: nil)
        addEntry(info.containerPath, mediaType: "application/oebps-package+xml", size: nil)
        for item in info.manifest ?? [] {
            addEntry(item.href, mediaType: item.mediaType, size: item.size)
        }
        guard entries.count > 2 else {
            throw ProviderError.invalidResponse
        }
        let hasOverlaySMIL = entries.contains {
            $0.path.lowercased().hasSuffix(".smil") || $0.mediaType?.localizedCaseInsensitiveContains("smil") == true
        }
        guard !hasOverlaySMIL else {

            throw ProviderError.notImplemented
        }

        let cacheDirName = resource.map { "book-\(book.id)-file-\($0.fileId)" } ?? "book-\(book.id)"
        let cacheRoot = ebooks.streamedEpubCacheRoot
            .appendingPathComponent(connection.id.uuidString, isDirectory: true)
            .appendingPathComponent(cacheDirName, isDirectory: true)

        return GrimmoryEpubStreamingSession(
            entries: entries,
            cacheRoot: cacheRoot,
            fetchRemote: { path in
                try await self.fetchEpubStreamResource(bookId: bookId, path: path, queryItems: queryItems)
            }
        )
    }

    private func fetchEpubStreamResource(
        bookId: Int,
        path: String,
        queryItems: [URLQueryItem]
    ) async throws -> Data {
        let encodedPath =
            path
            .split(separator: "/")
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        let request = try makeRequest(path: "/api/v1/epub/\(bookId)/file/\(encodedPath)", queryItems: queryItems)
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            throw ProviderError.serverError("Failed to stream EPUB resource (HTTP \(response.statusCode))")
        }
        return data
    }

    func fetchFilePath(bookId: String) async -> String? {
        guard !useKomgaFallback else { return nil }
        let bookId =
            bookId.hasPrefix(Self.companionAudiobookIDPrefix)
            ? String(bookId.dropFirst(Self.companionAudiobookIDPrefix.count))
            : bookId
        do {
            let request = try makeRequest(path: "/api/v1/books/\(bookId)")
            let (data, response) = try await performAuthorizedRequest(request)
            guard response.statusCode == 200 else { return nil }

            struct FilePathResponse: Decodable {
                let primaryFile: BooklorePrimaryFile?
            }
            let decoded = try JSONDecoder().decode(FilePathResponse.self, from: data)
            return decoded.primaryFile?.filePath
        } catch {
            AppLogger.network.error("[Booklore] fetchFilePath failed for book \(bookId): \(error.localizedDescription)")
            return nil
        }
    }

    func fetchGrimmorySyncDetail(bookId: Int) async throws -> BookloreSyncBookDetail {
        let request = try makeRequest(path: "/api/v1/app/books/\(bookId)")
        let (data, response) = try await performAuthorizedRequest(request)
        guard response.statusCode == 200 else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw ProviderError.unauthorized
            }
            throw ProviderError.serverError(
                "Failed to resolve Grimmory ebook files (HTTP \(response.statusCode))"
            )
        }
        return try JSONDecoder().decode(BookloreSyncBookDetail.self, from: data)
    }

    private func grimmoryEbookFormat(
        for file: BookloreBookFile,
        preferredFormat: String?
    ) -> String? {
        let candidates = [
            file.fileExtension,
            file.fileType,
            file.bookType,
            file.fileName.map { URL(fileURLWithPath: $0).pathExtension },
            file.filePath.map { URL(fileURLWithPath: $0).pathExtension },
        ]
        if let format = candidates.lazy.compactMap(BookloreBookMapper.normalizedEbookFormat).first {
            return format
        }
        let normalized = Set(candidates.compactMap(BookloreBookMapper.normalizedFileType).map { $0.lowercased() })
        if normalized.contains("cbx") {
            if let preferredFormat,
                [EbookFormat.cbz.rawValue, EbookFormat.cbr.rawValue, EbookFormat.imagefolder.rawValue]
                    .contains(preferredFormat)
            {
                return preferredFormat
            }
            return EbookFormat.cbz.rawValue
        }
        return nil
    }

    func selectedGrimmoryEbookResource(
        for book: Book,
        bookId: Int,
        detail: BookloreSyncBookDetail
    ) throws -> GrimmoryEbookResource? {
        let declaredFormat = BookloreBookMapper.normalizedEbookFormat(book.ebookFormat)
        let files = detail.files ?? []
        let cacheKey = "\(book.id):\(declaredFormat ?? "primary")"
        if let cached = cachedEbookResources[cacheKey],
            cached.bookId == bookId,
            files.contains(where: {
                $0.id?.stringValue == String(cached.fileId)
            })
        {
            return cached
        }

        let matchingFiles = files.filter { file in
            guard let declaredFormat else { return grimmoryEbookFormat(for: file, preferredFormat: nil) != nil }
            guard let fileFormat = grimmoryEbookFormat(for: file, preferredFormat: declaredFormat) else { return false }
            if [EbookFormat.cbz.rawValue, EbookFormat.cbr.rawValue, EbookFormat.imagefolder.rawValue]
                .contains(declaredFormat)
            {
                return [EbookFormat.cbz.rawValue, EbookFormat.cbr.rawValue, EbookFormat.imagefolder.rawValue]
                    .contains(fileFormat)
            }
            if EbookFormat.mobiExtensions.contains(declaredFormat) {
                return EbookFormat.mobiExtensions.contains(fileFormat)
            }
            return fileFormat == declaredFormat
        }
        guard
            let selected = matchingFiles.first(where: { $0.isPrimary == true })
                ?? matchingFiles.first,
            let rawFileId = selected.id?.stringValue,
            let fileId = Int(rawFileId),
            fileId > 0
        else {
            throw ProviderError.serverError("No matching ebook file is available for this Grimmory book")
        }

        return GrimmoryEbookResource(
            bookId: bookId,
            fileId: fileId,
            isPrimary: selected.isPrimary == true,
            fileName: selected.fileName,
            format: grimmoryEbookFormat(for: selected, preferredFormat: declaredFormat)
        )
    }

    func cacheGrimmoryResource(
        _ resource: GrimmoryEbookResource,
        for book: Book
    ) {
        let format = BookloreBookMapper.normalizedEbookFormat(book.ebookFormat) ?? "primary"
        cachedEbookResources["\(book.id):\(format)"] = resource
    }

    func resolveGrimmoryEbookResource(
        for book: Book
    ) async throws -> GrimmoryEbookResource? {
        guard let bookId = resolveGrimmoryBookId(for: book) else {
            throw ProviderError.invalidResponse
        }
        let detail = try await fetchGrimmorySyncDetail(bookId: bookId)
        let resource = try selectedGrimmoryEbookResource(
            for: book,
            bookId: bookId,
            detail: detail
        )
        if let resource {
            cacheGrimmoryResource(resource, for: book)
        }
        return resource
    }

    private func grimmoryResourceCacheIdentifier(
        for book: Book,
        resource: GrimmoryEbookResource
    ) -> String {
        "grimmory-\(connection.id.uuidString)-\(book.id)-file-\(resource.fileId)"
    }

    func downloadEbook(for book: Book, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> URL {
        let resource = try await resolveGrimmoryEbookResource(for: book)
        let cacheIdentifier =
            resource.map {
                grimmoryResourceCacheIdentifier(for: book, resource: $0)
            } ?? book.id
        let expectedExtension = resource?.format
            ?? BookloreBookMapper.normalizedEbookFormat(book.ebookFormat)

        if let cached = ebooks.cachedEbook(forBookId: cacheIdentifier) {
            if expectedExtension == nil || cached.pathExtension.lowercased() == expectedExtension {
                AppLogger.network.info("Using cached ebook for \(book.title) (\(book.id))")
                onProgress?(1)
                return cached
            }
            try? ebooks.deleteRemoteEbookArtifacts(forBookId: cacheIdentifier)
        }

        AppLogger.network.info("Downloading ebook: \(book.title) (\(book.id))")
        let downloadPath: String
        if let resource {
            downloadPath =
                resource.isPrimary
                ? "/api/v1/books/\(resource.bookId)/download"
                : "/api/v1/books/\(resource.bookId)/files/\(resource.fileId)/download"
        } else {
            downloadPath = "/api/v1/books/\(book.id)/download"
        }
        let request = try makeRequest(path: downloadPath)
        let (localURL, httpResponse) = try await performAuthorizedDownload(request, onProgress: onProgress)
        guard httpResponse.statusCode == 200 else {
            throw ProviderError.serverError("Failed to download ebook (HTTP \(httpResponse.statusCode))")
        }

        let ext = EbookFormat.detectedExtension(inDownloadResponse: httpResponse) ?? expectedExtension ?? "epub"
        let safeTitle =
            resource?.fileName
            .map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? book.title.replacingOccurrences(of: "/", with: "-")
        AppLogger.network.info("Downloaded ebook: \(book.title) (\(ext), \(localURL.lastPathComponent))")
        let cachedURL = try ebooks.cacheRemoteEbook(
            tempURL: localURL,
            preferredFilename: "\(safeTitle).\(ext)",
            bookIdentifier: cacheIdentifier
        )
        onProgress?(1)
        return cachedURL
    }
}
