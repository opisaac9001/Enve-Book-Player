import Foundation

enum ReaderAnnotationStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case highlight
    case underline
    case strikethrough
    case squiggly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .highlight:
            return "Highlight"
        case .underline:
            return "Underline"
        case .strikethrough:
            return "Strike"
        case .squiggly:
            return "Squiggle"
        }
    }

    var systemImage: String {
        switch self {
        case .highlight:
            return "highlighter"
        case .underline:
            return "underline"
        case .strikethrough:
            return "strikethrough"
        case .squiggly:
            return "scribble.variable"
        }
    }
}

struct ReaderAnnotation: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let bookId: String
    var locator: String?
    var position: Double
    var text: String
    var note: String?
    var colorHex: String
    var style: ReaderAnnotationStyle
    var chapterTitle: String?
    var createdAt: Date
    var updatedAt: Date
    var remoteID: Int?
    var isRemotePlaceholder: Bool

    init(
        id: String = UUID().uuidString,
        bookId: String,
        locator: String? = nil,
        position: Double = 0,
        text: String,
        note: String? = nil,
        colorHex: String = "#FFF59D",
        style: ReaderAnnotationStyle = .highlight,
        chapterTitle: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        remoteID: Int? = nil,
        isRemotePlaceholder: Bool = false
    ) {
        self.id = id
        self.bookId = bookId
        self.locator = locator
        self.position = position
        self.text = text
        self.note = note
        self.colorHex = colorHex
        self.style = style
        self.chapterTitle = chapterTitle
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.remoteID = remoteID
        self.isRemotePlaceholder = isRemotePlaceholder
    }

    var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: updatedAt)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        bookId = try container.decode(String.self, forKey: .bookId)
        locator = try container.decodeIfPresent(String.self, forKey: .locator)
        position = try container.decodeIfPresent(Double.self, forKey: .position) ?? 0
        text = try container.decode(String.self, forKey: .text)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#FFF59D"
        style = try container.decodeIfPresent(ReaderAnnotationStyle.self, forKey: .style) ?? .highlight
        chapterTitle = try container.decodeIfPresent(String.self, forKey: .chapterTitle)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        remoteID = try container.decodeIfPresent(Int.self, forKey: .remoteID)
        isRemotePlaceholder = try container.decodeIfPresent(Bool.self, forKey: .isRemotePlaceholder) ?? false
    }
}
