import Foundation

struct FlexibleID: Decodable {
    let stringValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            stringValue = string
        } else if let int = try? container.decode(Int.self) {
            stringValue = String(int)
        } else if let int64 = try? container.decode(Int64.self) {
            stringValue = String(int64)
        } else {
            throw DecodingError.typeMismatch(
                String.self,
                .init(codingPath: decoder.codingPath, debugDescription: "Expected string or integer ID")
            )
        }
    }
}

struct FlexibleDate: Decodable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let epoch = try? container.decode(Double.self) {
            date = Self.date(fromEpoch: epoch)
        } else if let string = try? container.decode(String.self) {
            date = Self.parse(string)
        } else {
            date = nil
        }
    }

    nonisolated static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let epoch = Double(value) {
            return date(fromEpoch: epoch)
        }
        return ISO8601Timestamp.parse(value)
    }

    nonisolated private static func date(fromEpoch value: Double) -> Date {
        Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
    }
}

struct BookloreEpubProgress: Decodable {
    let percentage: Double?
    let cfi: String?
    let href: String?
    let updatedAt: String?
}

struct BooklorePage<T: Decodable>: Decodable {
    let content: [T]
    let page: Int
    let size: Int
    let totalElements: Int
    let totalPages: Int
    let hasNext: Bool
    let hasPrevious: Bool
    let rejectedItems: [RejectedContentCandidate]
    var rawItemCount: Int { content.count + rejectedItems.count }

    private enum CodingKeys: String, CodingKey {
        case content, page, size, totalElements, totalPages, hasNext, hasPrevious
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let content = try container.decode(LossyDecodableArray<T>.self, forKey: .content)
        self.content = content.values
        rejectedItems = content.rejectedItems
        page = try container.decode(Int.self, forKey: .page)
        size = try container.decode(Int.self, forKey: .size)
        totalElements = try container.decode(Int.self, forKey: .totalElements)
        totalPages = try container.decode(Int.self, forKey: .totalPages)
        hasNext = try container.decode(Bool.self, forKey: .hasNext)
        hasPrevious = try container.decode(Bool.self, forKey: .hasPrevious)
    }
}

struct BooklorePrimaryFile: Decodable {
    let fileName: String?
    let filePath: String?
    let fileSubPath: String?
    let bookType: String?
    let fileType: String?
    let fileExtension: String?

    enum CodingKeys: String, CodingKey {
        case fileName
        case filePath
        case fileSubPath
        case bookType
        case fileType
        case type
        case format
        case fileExtension
        case extensionValue = "extension"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        fileSubPath = try container.decodeIfPresent(String.self, forKey: .fileSubPath)
        bookType = try container.decodeIfPresent(String.self, forKey: .bookType)
        fileType =
            try container.decodeIfPresent(String.self, forKey: .fileType)
            ?? container.decodeIfPresent(String.self, forKey: .type)
            ?? container.decodeIfPresent(String.self, forKey: .format)
        fileExtension =
            try container.decodeIfPresent(String.self, forKey: .fileExtension)
            ?? container.decodeIfPresent(String.self, forKey: .extensionValue)
    }
}

struct BookloreBookSummary: Decodable {
    let id: FlexibleID
    let title: String
    let authors: [String]?
    let thumbnailUrl: String?
    let audiobookCoverUpdatedOn: String?
    let duration: Double?
    let seriesName: String?
    let seriesNumber: Double?
    let libraryId: FlexibleID?
    let addedOn: FlexibleDate?
    let publishedDate: String?
    let personalRating: Double?
    let goodreadsRating: Double?
    let readProgress: Double?
    let readStatus: String?
    let primaryFileType: String?
    let primaryFileName: String?
    let durationSeconds: Int?
    let dateFinished: String?
    let lastReadTime: String?
    let epubProgress: BookloreEpubProgress?
    let primaryFile: BooklorePrimaryFile?
    let publisher: String?
    let categories: [String]?
    let language: String?
    let narrator: String?
    let isbn13: String?
    let isbn10: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case authors
        case thumbnailUrl
        case audiobookCoverUpdatedOn
        case duration
        case durationMs
        case seriesName
        case seriesNumber
        case libraryId
        case addedOn
        case publishedDate
        case personalRating
        case goodreadsRating
        case readProgress
        case readStatus
        case primaryFileType
        case fileType
        case type
        case format
        case primaryFileName
        case durationSeconds
        case dateFinished
        case lastReadTime
        case epubProgress
        case primaryFile
        case publisher
        case categories
        case language
        case narrator
        case isbn13
        case isbn10
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(FlexibleID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        authors = try container.decodeIfPresent([String].self, forKey: .authors)
        thumbnailUrl = try container.decodeIfPresent(String.self, forKey: .thumbnailUrl)
        audiobookCoverUpdatedOn = try container.decodeIfPresent(String.self, forKey: .audiobookCoverUpdatedOn)
        let durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
        let durationPlain = try container.decodeIfPresent(Double.self, forKey: .duration)
        duration = durationMs.map { $0 / 1000 } ?? durationPlain.map { $0 > 10_000 ? $0 / 1000 : $0 }
        seriesName = try container.decodeIfPresent(String.self, forKey: .seriesName)
        seriesNumber = try container.decodeIfPresent(Double.self, forKey: .seriesNumber)
        libraryId = try container.decodeIfPresent(FlexibleID.self, forKey: .libraryId)
        addedOn = try container.decodeIfPresent(FlexibleDate.self, forKey: .addedOn)
        publishedDate = try container.decodeIfPresent(String.self, forKey: .publishedDate)
        personalRating = try container.decodeIfPresent(Double.self, forKey: .personalRating)
        goodreadsRating = try container.decodeIfPresent(Double.self, forKey: .goodreadsRating)
        readProgress = try container.decodeIfPresent(Double.self, forKey: .readProgress)
        readStatus = try container.decodeIfPresent(String.self, forKey: .readStatus)
        primaryFileType =
            try container.decodeIfPresent(String.self, forKey: .primaryFileType)
            ?? container.decodeIfPresent(String.self, forKey: .fileType)
            ?? container.decodeIfPresent(String.self, forKey: .type)
            ?? container.decodeIfPresent(String.self, forKey: .format)
        primaryFileName = try container.decodeIfPresent(String.self, forKey: .primaryFileName)
        durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
        dateFinished = try container.decodeIfPresent(String.self, forKey: .dateFinished)
        lastReadTime = try container.decodeIfPresent(String.self, forKey: .lastReadTime)
        epubProgress = try container.decodeIfPresent(BookloreEpubProgress.self, forKey: .epubProgress)
        primaryFile = try container.decodeIfPresent(BooklorePrimaryFile.self, forKey: .primaryFile)
        publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
        categories = try container.decodeIfPresent([String].self, forKey: .categories)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        narrator = try container.decodeIfPresent(String.self, forKey: .narrator)
        isbn13 = try container.decodeIfPresent(String.self, forKey: .isbn13)
        isbn10 = try container.decodeIfPresent(String.self, forKey: .isbn10)
    }
}

struct BookloreLegacyLibrary: Decodable {
    let id: FlexibleID
    let name: String
    let allowedFormats: [String]?
}

struct BookloreLegacyBook: Decodable {
    struct FileProgress: Decodable {
        let percentage: Double?
    }
    let id: FlexibleID
    let libraryId: FlexibleID?
    let name: String?
    let title: String?
    let addedOn: FlexibleDate?
    let readStatus: String?
    let metadata: BookloreLegacyMetadata?
    let primaryFile: BookloreLegacyBookFile?
    let alternativeFormats: [BookloreLegacyBookFile]?
    let epubProgress: BookloreEpubProgress?
    let pdfProgress: FileProgress?

    var hasAudiobookAlternative: Bool {
        (alternativeFormats ?? []).contains { ($0.bookType ?? "").uppercased() == "AUDIOBOOK" }
    }
}

struct BookloreLegacyMetadata: Decodable {
    let title: String?
    let authors: [String]?
    let seriesName: String?
    let seriesNumber: Float?
    let description: String?
    let publisher: String?
    let narrator: String?
    let audiobookCoverUpdatedOn: String?
}

struct BookloreLegacyBookFile: Decodable {
    let bookType: String?
    let fileType: String?
    let fileExtension: String?
    let fileName: String?
    let filePath: String?
    let folderBased: Bool?

    enum CodingKeys: String, CodingKey {
        case bookType
        case fileType
        case type
        case format
        case fileExtension
        case extensionValue = "extension"
        case fileName
        case filename
        case filePath
        case folderBased
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookType = try container.decodeIfPresent(String.self, forKey: .bookType)
        fileType =
            try container.decodeIfPresent(String.self, forKey: .fileType)
            ?? container.decodeIfPresent(String.self, forKey: .type)
            ?? container.decodeIfPresent(String.self, forKey: .format)
        fileExtension =
            try container.decodeIfPresent(String.self, forKey: .fileExtension)
            ?? container.decodeIfPresent(String.self, forKey: .extensionValue)
        fileName =
            try container.decodeIfPresent(String.self, forKey: .fileName)
            ?? container.decodeIfPresent(String.self, forKey: .filename)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        folderBased = try container.decodeIfPresent(Bool.self, forKey: .folderBased)
    }
}
