import Foundation

enum BookloreCatalogMapper {
    struct Context {
        let providerId: UUID
        let libraryId: String
        let source: Book.BookSource
        let serverURL: String
    }

    static func book(from summary: BookloreBookSummary, context: Context) -> Book {
        let seriesInfo = BookloreBookMapper.normalizedSeriesInfo(name: summary.seriesName, sequence: summary.seriesNumber.map { String($0) })

        let knownEbookFileTypes: Set<String> = ["EPUB", "PDF", "CBX", "CBR", "CBZ", "FB2", "MOBI", "AZW3", "AZW"]
        let resolvedType = resolvedFileType(primaryFileType: summary.primaryFileType, primaryFile: summary.primaryFile)
        let primaryIsRealEbook = (resolvedType?.uppercased()).map(knownEbookFileTypes.contains) ?? false
        let hasAudiobookSignal = summary.audiobookCoverUpdatedOn != nil || (summary.thumbnailUrl?.contains("/audiobook-") == true)

        var detectedMediaType = BookloreBookMapper.mediaType(from: resolvedType)
        var isDualFormatEbook = false
        if detectedMediaType != .audiobook, hasAudiobookSignal {
            if primaryIsRealEbook {
                isDualFormatEbook = true
            } else {
                detectedMediaType = .audiobook
            }
        }
        let readProg =
            BookloreBookMapper.fraction(fromReadProgress: summary.readProgress)
            ?? BookloreBookMapper.fraction(fromPercent: summary.epubProgress?.percentage)
            ?? 0
        let duration: Double? = summary.durationSeconds.map { Double($0) } ?? summary.duration.flatMap { $0 > 0 ? $0 : nil }
        let currentTime =
            detectedMediaType == .audiobook && (duration ?? 0) > 0
            ? readProg * (duration ?? 0)
            : 0
        let serverReadStatus = summary.readStatus?.uppercased()
        let isFinished = readProg >= Book.finishedProgressThreshold || serverReadStatus == "READ" || summary.dateFinished != nil
        let hideFromContinue = BookloreBookMapper.statusSuppressesContinue(serverReadStatus)

        let lastUpdate =
            FlexibleDate.parse(summary.dateFinished)
            ?? FlexibleDate.parse(summary.lastReadTime)
            ?? summary.addedOn?.date
            ?? Date()

        let resolvedFilePath = summary.primaryFile?.filePath ?? summary.primaryFileName
        let resolvedTitle: String = {
            if detectedMediaType == .audiobook,
                let titleFromFile = BookloreBookMapper.title(fromPrimaryFileName: summary.primaryFileName ?? summary.primaryFile?.fileName)
            {
                return titleFromFile
            }
            return summary.title
        }()

        let coverURL = BookloreBookMapper.absoluteURL(
            from: summary.thumbnailUrl,
            serverURL: context.serverURL,
            mediaType: detectedMediaType
        )
        let versionedCoverURL = BookloreBookMapper.versionedCoverURL(
            coverURL,
            updatedOn: detectedMediaType == .audiobook ? summary.audiobookCoverUpdatedOn : nil
        )

        var result = Book(
            id: summary.id.stringValue,
            title: resolvedTitle,
            author: BookloreBookMapper.displayAuthor(from: summary.authors),
            authors: summary.authors,
            narrator: summary.narrator,
            seriesInfo: seriesInfo,
            duration: duration,
            coverURL: versionedCoverURL,
            mediaType: detectedMediaType,
            epubLocator: nil,
            ebookProgress: detectedMediaType == .ebook ? readProg : nil,
            hideFromContinue: hideFromContinue,
            dateAdded: summary.addedOn?.date,
            description: nil,
            genres: summary.categories,
            chapters: [],
            publisher: summary.publisher,
            currentTime: currentTime,
            isFinished: isFinished,
            lastUpdate: lastUpdate,
            libraryId: summary.libraryId?.stringValue ?? context.libraryId,
            providerId: context.providerId,
            source: context.source,
            rawMetadata: nil,
            filePath: resolvedFilePath,
            publishedYear: BookloreBookMapper.publishedYear(from: summary.publishedDate),
            personalRating: summary.personalRating.map { $0 / 2 },
            goodreadsRating: summary.goodreadsRating,
            language: summary.language
        )
        result.isbn = summary.isbn13 ?? summary.isbn10
        result.serverReadStatus = serverReadStatus
        if detectedMediaType == .ebook {
            result.ebookFormat = BookloreBookMapper.normalizedEbookFormat(resolvedType)
        }
        if isDualFormatEbook {
            result.hasAlternateFormat = true
        }
        return result
    }

    static func book(from legacy: BookloreLegacyBook, context: Context) -> Book {
        let resolvedType = resolvedFileType(file: legacy.primaryFile)
        let mediaType = BookloreBookMapper.mediaType(from: resolvedType)
        let title = {
            if mediaType == .audiobook,
                let titleFromFile = BookloreBookMapper.title(fromPrimaryFileName: legacy.primaryFile?.fileName ?? legacy.primaryFile?.filePath)
            {
                return titleFromFile
            }
            return legacy.title ?? legacy.metadata?.title ?? legacy.name ?? "Unknown"
        }()
        let author = BookloreBookMapper.displayAuthor(from: legacy.metadata?.authors)
        let legacyAuthors: [String]? = legacy.metadata?.authors
        let narrator = legacy.metadata?.narrator
        let seriesInfo = BookloreBookMapper.normalizedSeriesInfo(
            name: legacy.metadata?.seriesName,
            sequence: legacy.metadata?.seriesNumber.map { String($0) }
        )
        let serverReadStatus = legacy.readStatus?.uppercased()
        let isAudiobook = mediaType == .audiobook
        let coverPath =
            isAudiobook
            ? "/api/books/\(legacy.id.stringValue)/audiobook-cover"
            : "/api/books/\(legacy.id.stringValue)/cover"
        let coverURL = BookloreBookMapper.absoluteURL(from: coverPath, serverURL: context.serverURL)
        var result = Book(
            id: legacy.id.stringValue,
            title: title,
            author: author,
            authors: legacyAuthors,
            narrator: narrator,
            seriesInfo: seriesInfo,
            duration: 0,
            coverURL: coverURL,
            mediaType: mediaType,
            hideFromContinue: BookloreBookMapper.statusSuppressesContinue(serverReadStatus),
            dateAdded: legacy.addedOn?.date,
            description: legacy.metadata?.description,
            genres: [],
            chapters: [],
            publisher: legacy.metadata?.publisher,
            progress: 0,
            currentTime: 0,
            isFinished: serverReadStatus == "READ",
            lastUpdate: legacy.addedOn?.date ?? Date(),
            libraryId: legacy.libraryId?.stringValue ?? context.libraryId,
            providerId: context.providerId,
            source: context.source,
            rawMetadata: nil
        )
        result.serverReadStatus = serverReadStatus

        if mediaType == .ebook, legacy.hasAudiobookAlternative {
            result.hasAlternateFormat = true
        }
        if mediaType == .ebook {
            result.ebookFormat = BookloreBookMapper.normalizedEbookFormat(resolvedType)
        }
        return applyingFormats(legacy, to: result)
    }

    static func isEbookType(_ type: String?) -> Bool {
        guard let type else { return false }
        return ["EPUB", "PDF", "CBX", "CBR", "CBZ", "FB2", "MOBI", "AZW3", "AZW"].contains(type.uppercased())
    }

    static func applyingFormats(_ legacy: BookloreLegacyBook, to book: Book) -> Book {
        let files = [legacy.primaryFile].compactMap { $0 } + (legacy.alternativeFormats ?? [])
        guard let ebookFile = files.first(where: { isEbookType(resolvedFileType(file: $0)) }),
            files.contains(where: { BookloreBookMapper.mediaType(from: resolvedFileType(file: $0)) == .audiobook })
        else { return book }

        var result = Book(
            id: book.id,
            title: legacy.title ?? legacy.metadata?.title ?? book.title,
            author: book.author,
            authors: book.authors,
            narrator: book.narrator,
            seriesInfo: book.seriesInfo,
            duration: nil,
            coverURL: book.coverURL,
            mediaType: .ebook,
            hideFromContinue: book.hideFromContinue,
            dateAdded: book.dateAdded,
            description: book.description,
            genres: book.genres,
            publisher: book.publisher,
            lastUpdate: book.lastUpdate,
            libraryId: book.libraryId,
            providerId: book.providerId,
            source: book.source,
            rawMetadata: book.rawMetadata,
            filePath: ebookFile.filePath ?? ebookFile.fileName,
            epub3Features: book.epub3Features,
            publishedYear: book.publishedYear,
            personalRating: book.personalRating,
            goodreadsRating: book.goodreadsRating,
            language: book.language
        )
        result.isbn = book.isbn
        result.serverReadStatus = book.serverReadStatus
        result.ebookFormat = BookloreBookMapper.normalizedEbookFormat(resolvedFileType(file: ebookFile))
        result.hasAlternateFormat = true
        // Absent per-file progress falls back to the summary-mapped fraction and finished state.
        result.ebookProgress =
            BookloreBookMapper.fraction(fromPercent: legacy.epubProgress?.percentage ?? legacy.pdfProgress?.percentage)
            ?? book.progressPercentage
        result.isFinished =
            book.isFinished || (result.ebookProgress ?? 0) >= Book.finishedProgressThreshold || legacy.readStatus?.uppercased() == "READ"
        return result
    }

    static func resolvedFileType(primaryFileType: String?, primaryFile: BooklorePrimaryFile?) -> String? {
        BookloreBookMapper.resolvedFileType([
            primaryFile?.fileType,
            primaryFile?.fileExtension,
            primaryFile?.bookType,
            primaryFileType,
            BookloreBookMapper.fileExtension(from: primaryFile?.fileName),
            BookloreBookMapper.fileExtension(from: primaryFile?.filePath),
            BookloreBookMapper.fileExtension(from: primaryFile?.fileSubPath),
        ])
    }

    private static func resolvedFileType(file: BookloreLegacyBookFile?) -> String? {
        BookloreBookMapper.resolvedFileType([
            file?.fileType,
            file?.fileExtension,
            file?.bookType,
            BookloreBookMapper.fileExtension(from: file?.fileName),
            BookloreBookMapper.fileExtension(from: file?.filePath),
        ])
    }
}

nonisolated struct GrimmoryTrack: Decodable {
    let index: Int?
    let fileName: String?
    let title: String?
    let duration: Double?
    let mimeType: String?
    let cumulativeStart: Double?

    private enum CodingKeys: String, CodingKey {
        case index
        case trackIndex
        case fileName
        case filename
        case title
        case duration
        case durationMs
        case mimeType
        case contentType
        case cumulativeStart
        case cumulativeStartMs
        case startOffset
        case startOffsetMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index =
            try container.decodeIfPresent(Int.self, forKey: .index)
            ?? container.decodeIfPresent(Int.self, forKey: .trackIndex)
        fileName =
            try container.decodeIfPresent(String.self, forKey: .fileName)
            ?? container.decodeIfPresent(String.self, forKey: .filename)
        title = try container.decodeIfPresent(String.self, forKey: .title)

        let durationMilliseconds = try container.decodeIfPresent(Double.self, forKey: .durationMs)
        let durationValue = try container.decodeIfPresent(Double.self, forKey: .duration)
        duration = durationMilliseconds.map { $0 / 1_000 }
            ?? durationValue.map { $0 > 10_000 ? $0 / 1_000 : $0 }
        mimeType =
            try container.decodeIfPresent(String.self, forKey: .mimeType)
            ?? container.decodeIfPresent(String.self, forKey: .contentType)
        let startMilliseconds =
            try container.decodeIfPresent(Double.self, forKey: .cumulativeStartMs)
            ?? container.decodeIfPresent(Double.self, forKey: .startOffsetMs)
        let startValue =
            try container.decodeIfPresent(Double.self, forKey: .cumulativeStart)
            ?? container.decodeIfPresent(Double.self, forKey: .startOffset)
        cumulativeStart = startMilliseconds.map { $0 / 1_000 }
            ?? startValue.map { $0 > 10_000 ? $0 / 1_000 : $0 }
    }
}

nonisolated struct GrimmoryChapter: Decodable {
    let title: String?
    let start: Double?
    let end: Double?

    private enum CodingKeys: String, CodingKey {
        case title
        case start
        case end
        case startTimeMs
        case endTimeMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)

        let startMilliseconds = try container.decodeIfPresent(Double.self, forKey: .startTimeMs)
        let startValue = try container.decodeIfPresent(Double.self, forKey: .start)
        let endMilliseconds = try container.decodeIfPresent(Double.self, forKey: .endTimeMs)
        let endValue = try container.decodeIfPresent(Double.self, forKey: .end)
        start = startMilliseconds.map { $0 / 1_000 }
            ?? startValue.map { $0 > 10_000 ? $0 / 1_000 : $0 }
        end = endMilliseconds.map { $0 / 1_000 }
            ?? endValue.map { $0 > 10_000 ? $0 / 1_000 : $0 }
    }
}

nonisolated struct BookloreAudiobookInfo: Decodable {
    let bookId: Int?
    let bookFileId: Int?
    let title: String?
    let author: String?
    let narrator: String?
    let duration: Double?
    let tracks: [GrimmoryTrack]?
    let chapters: [GrimmoryChapter]?

    private enum CodingKeys: String, CodingKey {
        case bookId
        case bookFileId
        case title
        case author
        case narrator
        case duration
        case durationMs
        case tracks
        case chapters
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookId = try container.decodeIfPresent(Int.self, forKey: .bookId)
        bookFileId = try container.decodeIfPresent(Int.self, forKey: .bookFileId)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        narrator = try container.decodeIfPresent(String.self, forKey: .narrator)
        let durationMilliseconds = try container.decodeIfPresent(Double.self, forKey: .durationMs)
        let durationValue = try container.decodeIfPresent(Double.self, forKey: .duration)
        duration = durationMilliseconds.map { $0 / 1_000 }
            ?? durationValue.map { $0 > 10_000 ? $0 / 1_000 : $0 }
        tracks = try container.decodeIfPresent([GrimmoryTrack].self, forKey: .tracks)
        chapters = try container.decodeIfPresent([GrimmoryChapter].self, forKey: .chapters)
    }
}
