import Foundation
import Logging

extension BookloreProvider {
    enum CatalogFormatResolution {
        case resolved(books: [Book], isComplete: Bool)
        case batchEndpointUnsupported
    }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    // Mobile summaries omit alternate files; emitting them without batch-resolved format identity could downgrade dual-format records.
    func resolveCatalogFormats(_ books: [Book]) async throws -> CatalogFormatResolution {
        var resolved: [Book] = []
        resolved.reserveCapacity(books.count)
        var isComplete = true
        for start in stride(from: 0, to: books.count, by: 100) {
            let group = books[start..<min(start + 100, books.count)]
            let request = try makeRequest(
                path: "/api/v1/books/batch",
                queryItems: [URLQueryItem(name: "ids", value: group.map(\.id).joined(separator: ","))]
            )
            let (data, response) = try await performAuthorizedRequest(request)
            if start == 0, response.statusCode == 404 || response.statusCode == 405 {
                // No batch endpoint: only the legacy catalog carries full format identity.
                useLegacyCatalogFallback = true
                return .batchEndpointUnsupported
            }
            guard response.statusCode == 200 else {
                throw ProviderError.serverError("Alternate format batch returned HTTP \(response.statusCode)")
            }
            let formats = try JSONDecoder().decode([BookloreLegacyBook].self, from: data)
            let byId = Dictionary(formats.map { ($0.id.stringValue, $0) }, uniquingKeysWith: { first, _ in first })
            for book in group {
                if let format = byId[book.id] {
                    resolved.append(BookloreCatalogMapper.applyingFormats(format, to: book))
                } else {
                    isComplete = false
                }
            }
        }
        return .resolved(books: resolved, isComplete: isComplete)
    }

    func makeCompanionAudiobooks(forEbooks ebooks: inout [Book]) -> [Book] {
        var companions: [Book] = []
        for index in ebooks.indices {
            let ebook = ebooks[index]
            guard ebook.mediaType == .ebook,
                ebook.hasAlternateFormat,
                ebook.epub3Features?.hasMediaOverlay != true,
                !ebook.id.hasPrefix(Self.companionAudiobookIDPrefix)
            else { continue }

            let audiobookStableId = "grimmory:\(connection.id.uuidString):\(Self.companionAudiobookIDPrefix + ebook.id)"

            ebooks[index].linkedAudiobookStableId = audiobookStableId
            ebooks[index].hasAlternateFormat = false

            companions.append(makeCompanionAudiobook(forEbook: ebook))
        }
        return companions
    }

    func makeCompanionAudiobook(forEbook ebook: Book) -> Book {
        let audiobookId = Self.companionAudiobookIDPrefix + ebook.id
        let ebookStableId = "grimmory:\(connection.id.uuidString):\(ebook.id)"

        var audiobook = Book(
            id: audiobookId,
            title: ebook.title,
            author: ebook.author,
            authors: ebook.authors,
            narrator: nil,
            seriesInfo: ebook.seriesInfo,
            duration: nil,
            coverURL: absoluteURL(
                from: fallbackCoverPath(for: ebook.id, mediaType: .audiobook),
                mediaType: .audiobook
            ),
            mediaType: .audiobook,
            hideFromContinue: false,
            description: ebook.description,
            genres: ebook.genres,
            publisher: ebook.publisher,
            currentTime: 0,
            isFinished: false,
            lastUpdate: ebook.lastUpdate,
            libraryId: ebook.libraryId,
            providerId: connection.id,
            source: .booklore,
            rawMetadata: nil,
            filePath: nil,
            publishedYear: ebook.publishedYear,
            personalRating: ebook.personalRating,
            goodreadsRating: ebook.goodreadsRating
        )
        audiobook.linkedAudiobookStableId = ebookStableId
        return audiobook
    }

    func mapToBook(_ detail: BookloreBookDetail, fallbackLibraryId: String) -> Book {
        let seriesInfo = BookloreBookMapper.normalizedSeriesInfo(name: detail.seriesName, sequence: detail.seriesNumber.map { String($0) })

        let ebookFiles = detail.files?.filter { BookloreCatalogMapper.isEbookType(resolvedFileType(file: $0)) }
        let ebookFile = ebookFiles?.first(where: { $0.isPrimary == true }) ?? ebookFiles?.first
        let primaryFile = ebookFile ?? detail.files?.first(where: { $0.isPrimary == true }) ?? detail.files?.first
        let resolvedType =
            resolvedFileType(file: primaryFile)
            ?? BookloreCatalogMapper.resolvedFileType(primaryFileType: detail.primaryFileType, primaryFile: detail.primaryFile)
        let mediaType = BookloreBookMapper.mediaType(from: resolvedType)

        let hasBothFormats = ebookFile != nil && detail.files?.contains {
            BookloreBookMapper.mediaType(from: resolvedFileType(file: $0)) == .audiobook
        } == true
        let formatProgress = mediaType == .ebook
            ? detail.epubProgress?.percentage ?? detail.pdfProgress?.percentage
            : detail.audiobookProgress?.percentage
        let summaryProgress = mediaType == .ebook && hasBothFormats ? nil : detail.readProgress
        let readProg =
            BookloreBookMapper.fraction(fromPercent: formatProgress)
            ?? BookloreBookMapper.fraction(fromReadProgress: summaryProgress)
            ?? 0

        let duration: Double? = detail.durationSeconds.map { Double($0) } ?? detail.duration.flatMap { $0 > 0 ? $0 : nil }
        let fallbackThumbnail = fallbackCoverPath(for: detail.id.stringValue, mediaType: mediaType)
        let currentTime =
            mediaType == .audiobook && (duration ?? 0) > 0
            ? readProg * (duration ?? 0)
            : 0

        var resolvedTitle = detail.title
        if mediaType == .audiobook,
            let titleFromFile = BookloreBookMapper.title(fromPrimaryFileName: primaryFile?.fileName)
        {
            resolvedTitle = titleFromFile
        }

        let serverReadStatus = detail.readStatus?.uppercased()
        let isFinished = readProg >= Book.finishedProgressThreshold || serverReadStatus == "READ" || detail.dateFinished != nil
        let hideFromContinue = BookloreBookMapper.statusSuppressesContinue(serverReadStatus)

        let genres = detail.categories.map { Array($0) } ?? []

        let mappedChapters: [Chapter] =
            detail.chapters?.enumerated().map { (i, ch) in
                Chapter(
                    id: "grimmory_ch_\(i)",
                    start: ch.start ?? 0,
                    end: ch.end ?? (duration ?? 0),
                    title: ch.title ?? "Chapter \(i + 1)"
                )
            } ?? []

        let serverLocator: String?
        if detail.epubProgress != nil {
            serverLocator = nil
        } else if let page = detail.pdfProgress?.page {
            serverLocator = "{\"page\":\(page)}"
        } else {
            serverLocator = nil
        }

        let resolvedFilePath = primaryFile?.filePath ?? primaryFile?.fileName ?? detail.primaryFile?.filePath

        let readAloudTags = ["read aloud", "readaloud", "read-aloud"]
        var epub3Features: EPUB3Features? = nil
        if genres.contains(where: { tag in readAloudTags.contains(tag.lowercased()) }) {
            epub3Features = EPUB3Features(hasMediaOverlay: true, hasFixedLayout: false, smilFileCount: 1)
        }

        let bookId = detail.id.stringValue
        let author = BookloreBookMapper.displayAuthor(from: detail.authors)
        let detailAuthors: [String]? = detail.authors
        let cover =
            absoluteURL(from: detail.thumbnailUrl, mediaType: mediaType)
            ?? absoluteURL(from: fallbackThumbnail, mediaType: mediaType)

        let lastUpdate =
            parseDate(detail.dateFinished)
            ?? parseDate(detail.lastReadTime)
            ?? parseDate(detail.addedOn)
            ?? Date()

        let libId = detail.libraryId?.stringValue ?? fallbackLibraryId
        let ebProgress = mediaType == .ebook ? readProg : nil
        let backendId = connection.id.uuidString

        var result = Book(
            id: bookId,
            title: resolvedTitle,
            author: author,
            authors: detailAuthors,
            narrator: nil,
            seriesInfo: seriesInfo,
            duration: duration,
            coverURL: cover,
            mediaType: mediaType,
            epubLocator: serverLocator,
            ebookProgress: ebProgress,
            hideFromContinue: hideFromContinue,
            dateAdded: parseDate(detail.addedOn),
            description: detail.description,
            genres: genres,
            chapters: mappedChapters,
            publisher: detail.publisher,
            currentTime: currentTime,
            isFinished: isFinished,
            lastUpdate: lastUpdate,
            libraryId: libId,
            providerId: connection.id,
            backendId: backendId,
            source: .booklore,
            rawMetadata: nil,
            filePath: resolvedFilePath,
            epub3Features: epub3Features,
            publishedYear: BookloreBookMapper.publishedYear(from: detail.publishedDate),
            personalRating: detail.personalRating.map { $0 / 2 },
            goodreadsRating: detail.goodreadsRating
        )
        if mediaType == .ebook {
            result.ebookFormat = BookloreBookMapper.normalizedEbookFormat(resolvedType)
        }
        result.hasAlternateFormat = hasBothFormats
        result.serverReadStatus = serverReadStatus
        return result
    }
}
