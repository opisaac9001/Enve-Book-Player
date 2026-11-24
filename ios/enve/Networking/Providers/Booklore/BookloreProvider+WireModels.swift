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

    struct GrimmoryEbookResource {
        let bookId: Int
        let fileId: Int
        let isPrimary: Bool
        let fileName: String?
        let format: String?
    }
}
