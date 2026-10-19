import Foundation
import Logging

extension BookloreProvider {
    struct KomgaLibrary: Decodable {
        let id: String
        let name: String

        enum CodingKeys: String, CodingKey {
            case id, name
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)

            if let stringId = try? container.decode(String.self, forKey: .id) {
                id = stringId
            } else if let intId = try? container.decode(Int.self, forKey: .id) {
                id = String(intId)
            } else {
                throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "ID must be a String or Int")
            }
        }
    }

    struct KomgaPage<T: Decodable>: Decodable {
        let content: [T]
        let totalElements: Int
        let totalPages: Int
        let last: Bool?
        let rejectedItems: [RejectedContentCandidate]
        var rawItemCount: Int { content.count + rejectedItems.count }

        private enum CodingKeys: String, CodingKey {
            case content, totalElements, totalPages, last
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let content = try container.decode(LossyDecodableArray<T>.self, forKey: .content)
            self.content = content.values
            rejectedItems = content.rejectedItems
            totalElements = try container.decode(Int.self, forKey: .totalElements)
            totalPages = try container.decode(Int.self, forKey: .totalPages)
            last = try container.decodeIfPresent(Bool.self, forKey: .last)
        }
    }

    struct KomgaBook: Decodable {
        let id: String
        let seriesId: String
        let seriesTitle: String?
        let libraryId: String?
        let name: String
        let created: FlexibleDate?
        let summary: String?
        let size: String?
        let media: KomgaMedia?
        let metadata: KomgaMetadata?

        enum CodingKeys: String, CodingKey {
            case id, seriesId, seriesTitle, libraryId, name, created, summary, size, media, metadata
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)

            if let s = try? container.decode(String.self, forKey: .id) {
                id = s
            } else if let i = try? container.decode(Int.self, forKey: .id) {
                id = String(i)
            } else {
                id = "unknown"
            }

            if let s = try? container.decode(String.self, forKey: .seriesId) {
                seriesId = s
            } else if let i = try? container.decode(Int.self, forKey: .seriesId) {
                seriesId = String(i)
            } else {
                seriesId = ""
            }

            if let s = try? container.decode(String.self, forKey: .libraryId) {
                libraryId = s
            } else if let i = try? container.decode(Int.self, forKey: .libraryId) {
                libraryId = String(i)
            } else {
                libraryId = nil
            }

            seriesTitle = try container.decodeIfPresent(String.self, forKey: .seriesTitle)
            created = try container.decodeIfPresent(FlexibleDate.self, forKey: .created)
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            size = try? container.decodeIfPresent(String.self, forKey: .size)
            media = try? container.decodeIfPresent(KomgaMedia.self, forKey: .media)
            metadata = try? container.decodeIfPresent(KomgaMetadata.self, forKey: .metadata)
        }
    }

    struct KomgaMedia: Decodable {
        let pagesCount: Int?
        let mediaType: String?
    }

    struct KomgaMetadata: Decodable {
        let title: String?
        let summary: String?
        let number: String?
        let authors: [KomgaAuthor]?
    }

    struct KomgaAuthor: Decodable {
        let name: String
        let role: String
    }

    struct BookloreLoginRequest: Encodable {
        let username: String
        let password: String
    }

    struct BookloreLoginResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
    }

    struct BookloreAudiobookProgress: Decodable {
        let positionMs: Double?
        let trackIndex: Int?
        let percentage: Double?
        let updatedAt: String?
    }

    struct BooklorePdfProgress: Decodable {
        let page: Int?
        let percentage: Double?
        let updatedAt: String?
    }

    struct BookloreCbxProgress: Decodable {
        let page: Int?
        let percentage: Double?
        let updatedAt: String?
    }

    struct BookloreSyncBookDetail: Decodable {
        let readProgress: Double?
        let readStatus: String?
        let lastReadTime: String?
        let epubProgress: BookloreEpubProgress?
        let pdfProgress: BooklorePdfProgress?
        let cbxProgress: BookloreCbxProgress?
        let audiobookProgress: BookloreAudiobookProgress?
        let duration: Double?
        let durationSeconds: Int?
        let primaryFileType: String?
        let dateFinished: String?
        let files: [BookloreBookFile]?

        enum CodingKeys: String, CodingKey {
            case readProgress
            case readStatus
            case lastReadTime
            case epubProgress
            case pdfProgress
            case cbxProgress
            case audiobookProgress
            case duration
            case durationMs
            case durationSeconds
            case primaryFileType
            case fileType
            case type
            case format
            case dateFinished
            case files
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            readProgress = try container.decodeIfPresent(Double.self, forKey: .readProgress)
            readStatus = try container.decodeIfPresent(String.self, forKey: .readStatus)
            lastReadTime = try container.decodeIfPresent(String.self, forKey: .lastReadTime)
            epubProgress = try container.decodeIfPresent(BookloreEpubProgress.self, forKey: .epubProgress)
            pdfProgress = try container.decodeIfPresent(BooklorePdfProgress.self, forKey: .pdfProgress)
            cbxProgress = try container.decodeIfPresent(BookloreCbxProgress.self, forKey: .cbxProgress)
            audiobookProgress = try container.decodeIfPresent(BookloreAudiobookProgress.self, forKey: .audiobookProgress)
            let durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
            let durationPlain = try container.decodeIfPresent(Double.self, forKey: .duration)
            duration = durationMs.map { $0 / 1000 } ?? durationPlain.map { $0 > 10_000 ? $0 / 1000 : $0 }
            durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
            primaryFileType =
                try container.decodeIfPresent(String.self, forKey: .primaryFileType)
                ?? container.decodeIfPresent(String.self, forKey: .fileType)
                ?? container.decodeIfPresent(String.self, forKey: .type)
                ?? container.decodeIfPresent(String.self, forKey: .format)
            dateFinished = try container.decodeIfPresent(String.self, forKey: .dateFinished)
            files = try container.decodeIfPresent([BookloreBookFile].self, forKey: .files)
        }
    }

    struct AppNotebookEntry: Decodable, Sendable {
        enum EntryType: String, Decodable, Sendable {
            case bookmark = "BOOKMARK"
            case highlight = "HIGHLIGHT"
            case note = "NOTE"
        }

        let id: Int
        let type: EntryType
        let bookId: Int
        let text: String?
        let note: String?
        let color: String?
        let style: String?
        let createdAt: String?
        let updatedAt: String?
    }

    struct NotebookEntriesPage: Decodable {
        let content: [AppNotebookEntry]
        let hasNext: Bool?
    }

    struct RemoteBookmarkRecord: Decodable, Sendable {
        let id: Int
        let bookId: Int
        let cfi: String?
        let positionMs: Double?
        let trackIndex: Int?
        let title: String?
        let notes: String?
        let color: String?
        let priority: Int?
        let createdAt: String?
        let updatedAt: String?
    }

    struct RemoteAnnotationRecord: Decodable, Sendable {
        let id: Int
        let bookId: Int
        let cfi: String?
        let text: String?
        let color: String?
        let style: String?
        let note: String?
        let chapterTitle: String?
        let createdAt: String?
        let updatedAt: String?
    }

    struct RemoteBookNoteRecord: Decodable, Sendable {
        let id: Int
        let bookId: Int
        let cfi: String?
        let selectedText: String?
        let noteContent: String?
        let color: String?
        let chapterTitle: String?
        let createdAt: String?
        let updatedAt: String?
    }

    struct BookloreBookDetail: Decodable {
        let id: FlexibleID
        let title: String
        let authors: [String]?
        let thumbnailUrl: String?
        let duration: Double?
        let seriesName: String?
        let seriesNumber: Double?
        let libraryId: FlexibleID?
        let addedOn: FlexibleDate?
        let description: String?
        let publisher: String?
        let publishedDate: String?
        let personalRating: Double?
        let goodreadsRating: Double?
        let isbn13: String?
        let language: String?
        let libraryName: String?
        let readProgress: Double?
        let readStatus: String?
        let primaryFileType: String?
        let pageCount: Int?
        let files: [BookloreBookFile]?
        let audiobookProgress: BookloreAudiobookProgress?
        let epubProgress: BookloreEpubProgress?
        let pdfProgress: BooklorePdfProgress?
        let lastReadTime: String?
        let dateFinished: String?
        let durationSeconds: Int?
        let chapters: [GrimmoryChapter]?
        let categories: Set<String>?
        let primaryFile: BooklorePrimaryFile?

        enum CodingKeys: String, CodingKey {
            case id
            case title
            case authors
            case thumbnailUrl
            case duration
            case durationMs
            case seriesName
            case seriesNumber
            case libraryId
            case addedOn
            case description
            case publisher
            case publishedDate
            case personalRating
            case goodreadsRating
            case isbn13
            case language
            case libraryName
            case readProgress
            case readStatus
            case primaryFileType
            case fileType
            case type
            case format
            case pageCount
            case files
            case audiobookProgress
            case epubProgress
            case pdfProgress
            case lastReadTime
            case dateFinished
            case durationSeconds
            case chapters
            case categories
            case primaryFile
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(FlexibleID.self, forKey: .id)
            title = try container.decode(String.self, forKey: .title)
            authors = try container.decodeIfPresent([String].self, forKey: .authors)
            thumbnailUrl = try container.decodeIfPresent(String.self, forKey: .thumbnailUrl)
            let durationMs = try container.decodeIfPresent(Double.self, forKey: .durationMs)
            let durationPlain = try container.decodeIfPresent(Double.self, forKey: .duration)
            duration = durationMs.map { $0 / 1000 } ?? durationPlain.map { $0 > 10_000 ? $0 / 1000 : $0 }
            seriesName = try container.decodeIfPresent(String.self, forKey: .seriesName)
            seriesNumber = try container.decodeIfPresent(Double.self, forKey: .seriesNumber)
            libraryId = try container.decodeIfPresent(FlexibleID.self, forKey: .libraryId)
            addedOn = try container.decodeIfPresent(FlexibleDate.self, forKey: .addedOn)
            description = try container.decodeIfPresent(String.self, forKey: .description)
            publisher = try container.decodeIfPresent(String.self, forKey: .publisher)
            publishedDate = try container.decodeIfPresent(String.self, forKey: .publishedDate)
            personalRating = try container.decodeIfPresent(Double.self, forKey: .personalRating)
            goodreadsRating = try container.decodeIfPresent(Double.self, forKey: .goodreadsRating)
            isbn13 = try container.decodeIfPresent(String.self, forKey: .isbn13)
            language = try container.decodeIfPresent(String.self, forKey: .language)
            libraryName = try container.decodeIfPresent(String.self, forKey: .libraryName)
            readProgress = try container.decodeIfPresent(Double.self, forKey: .readProgress)
            readStatus = try container.decodeIfPresent(String.self, forKey: .readStatus)
            primaryFileType =
                try container.decodeIfPresent(String.self, forKey: .primaryFileType)
                ?? container.decodeIfPresent(String.self, forKey: .fileType)
                ?? container.decodeIfPresent(String.self, forKey: .type)
                ?? container.decodeIfPresent(String.self, forKey: .format)
            pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount)
            files = try container.decodeIfPresent([BookloreBookFile].self, forKey: .files)
            audiobookProgress = try container.decodeIfPresent(BookloreAudiobookProgress.self, forKey: .audiobookProgress)
            epubProgress = try container.decodeIfPresent(BookloreEpubProgress.self, forKey: .epubProgress)
            pdfProgress = try container.decodeIfPresent(BooklorePdfProgress.self, forKey: .pdfProgress)
            lastReadTime = try container.decodeIfPresent(String.self, forKey: .lastReadTime)
            dateFinished = try container.decodeIfPresent(String.self, forKey: .dateFinished)
            durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
            chapters = try container.decodeIfPresent([GrimmoryChapter].self, forKey: .chapters)
            categories = try container.decodeIfPresent(Set<String>.self, forKey: .categories)
            primaryFile = try container.decodeIfPresent(BooklorePrimaryFile.self, forKey: .primaryFile)
        }
    }

    struct BookloreBookFile: Decodable {
        let id: FlexibleID?
        let fileName: String?
        let filePath: String?
        let bookType: String?
        let fileType: String?
        let fileExtension: String?
        let isPrimary: Bool?
        let folderBased: Bool?

        enum CodingKeys: String, CodingKey {
            case id
            case fileName
            case filePath
            case bookType
            case fileType
            case type
            case format
            case fileExtension
            case extensionValue = "extension"
            case isPrimary
            case primary
            case folderBased
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(FlexibleID.self, forKey: .id)
            fileName = try container.decodeIfPresent(String.self, forKey: .fileName)
            filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
            bookType = try container.decodeIfPresent(String.self, forKey: .bookType)
            fileType =
                try container.decodeIfPresent(String.self, forKey: .fileType)
                ?? container.decodeIfPresent(String.self, forKey: .type)
                ?? container.decodeIfPresent(String.self, forKey: .format)
            fileExtension =
                try container.decodeIfPresent(String.self, forKey: .fileExtension)
                ?? container.decodeIfPresent(String.self, forKey: .extensionValue)
            isPrimary =
                try container.decodeIfPresent(Bool.self, forKey: .isPrimary)
                ?? container.decodeIfPresent(Bool.self, forKey: .primary)
            folderBased = try container.decodeIfPresent(Bool.self, forKey: .folderBased)
        }
    }

    struct GrimmoryEbookResource {
        let bookId: Int
        let fileId: Int
        let isPrimary: Bool
        let fileName: String?
        let format: String?
    }
}
