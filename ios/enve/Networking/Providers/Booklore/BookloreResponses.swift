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
    let contentSourceProgressPercent: Double?
}

// Grimmory's browse pages and Spring pages both nest paging metadata under `page`.
struct BooklorePage<T: Decodable>: Decodable {
    private struct Metadata: Decodable {
        let number: Int
        let size: Int
        let totalElements: Int
        let totalPages: Int
    }

    let content: [T]
    let page: Int
    let size: Int
    let totalElements: Int
    let totalPages: Int
    let rejectedItems: [RejectedContentCandidate]
    var rawItemCount: Int { content.count + rejectedItems.count }
    var hasNext: Bool { page + 1 < totalPages }

    private enum CodingKeys: String, CodingKey {
        case content, page
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let content = try container.decode(LossyDecodableArray<T>.self, forKey: .content)
        self.content = content.values
        rejectedItems = content.rejectedItems
        let metadata = try container.decode(Metadata.self, forKey: .page)
        guard metadata.number >= 0, metadata.size > 0, metadata.totalElements >= 0,
            metadata.totalPages == (metadata.totalElements == 0 ? 0 : 1 + (metadata.totalElements - 1) / metadata.size),
            content.values.count + content.rejectedItems.count <= metadata.size
        else {
            throw DecodingError.dataCorruptedError(forKey: .page, in: container, debugDescription: "Invalid page metadata")
        }
        page = metadata.number
        size = metadata.size
        totalElements = metadata.totalElements
        totalPages = metadata.totalPages
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

struct BookloreLegacyLibrary: Decodable {
    let id: FlexibleID
    let name: String
    let allowedFormats: [String]?
}

// Grimmory's `Book` DTO, returned by the browse, batch, book, and library endpoints.
struct BookloreLegacyBook: Decodable {
    struct PageProgress: Decodable {
        let page: Int?
        let percentage: Double?
    }

    struct PercentProgress: Decodable {
        let percentage: Double?
    }

    let id: FlexibleID
    let libraryId: FlexibleID?
    let libraryName: String?
    let name: String?
    let title: String?
    let addedOn: FlexibleDate?
    let lastReadTime: String?
    let dateFinished: String?
    let readStatus: String?
    let personalRating: Double?
    let metadata: BookloreLegacyMetadata?
    let primaryFile: BookloreLegacyBookFile?
    let alternativeFormats: [BookloreLegacyBookFile]?
    let epubProgress: BookloreEpubProgress?
    let pdfProgress: PageProgress?
    let cbxProgress: PageProgress?
    let koreaderProgress: PercentProgress?
    let koboProgress: PercentProgress?

    var files: [BookloreLegacyBookFile] {
        [primaryFile].compactMap { $0 } + (alternativeFormats ?? [])
    }

    func isPrimary(_ file: BookloreLegacyBookFile) -> Bool {
        guard let id = file.id?.stringValue else { return false }
        return id == primaryFile?.id?.stringValue
    }

    // Grimmory's readProgress source order; unlike readProgress, KOReader is already scaled to 0–100 here.
    var readProgressPercent: Double? {
        koreaderProgress?.percentage
            ?? koboProgress?.percentage
            ?? epubProgress?.percentage
            ?? pdfProgress?.percentage
            ?? cbxProgress?.percentage
    }

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
    let publishedDate: String?
    let narrator: String?
    let language: String?
    let isbn13: String?
    let isbn10: String?
    let goodreadsRating: Double?
    let categories: [String]?
    let audiobookCoverUpdatedOn: String?
}

struct BookloreLegacyBookFile: Decodable {
    let id: FlexibleID?
    let bookType: String?
    let fileType: String?
    let fileExtension: String?
    let fileName: String?
    let filePath: String?
    let folderBased: Bool?

    enum CodingKeys: String, CodingKey {
        case id
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
        id = try container.decodeIfPresent(FlexibleID.self, forKey: .id)
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
