import Foundation

enum BookIntelligenceScope: String, CaseIterable, Codable, Identifiable, Sendable {
    case previousChapter
    case currentChapterSoFar
    case lastTenMinutes
    case bookSoFar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .previousChapter: return "Previous Chapter"
        case .currentChapterSoFar: return "This Chapter"
        case .lastTenMinutes: return "Last 10 Min"
        case .bookSoFar: return "Book So Far"
        }
    }

    func title(for mediaType: AppMediaType) -> String {
        switch mediaType {
        case .ebook:
            switch self {
            case .previousChapter: return "Previous Chapter"
            case .currentChapterSoFar: return "This Chapter"
            case .lastTenMinutes: return "Recent Pages"
            case .bookSoFar: return "Book So Far"
            }
        default:
            switch self {
            case .previousChapter: return "Chapter End"
            case .currentChapterSoFar: return "Recent Chapter"
            case .lastTenMinutes: return "Last 2 Min"
            case .bookSoFar: return "Recent Context"
            }
        }
    }

    var promptName: String {
        switch self {
        case .previousChapter: return "the previous chapter"
        case .currentChapterSoFar: return "the current chapter up to the current playback position"
        case .lastTenMinutes: return "the last ten minutes"
        case .bookSoFar: return "the book so far"
        }
    }

    func promptName(for mediaType: AppMediaType) -> String {
        switch mediaType {
        case .ebook:
            switch self {
            case .previousChapter: return "the previous chapter"
            case .currentChapterSoFar: return "the current chapter up to the current reading position"
            case .lastTenMinutes: return "the recent pages before the current reading position"
            case .bookSoFar: return "the book so far"
            }
        default:
            switch self {
            case .previousChapter: return "the end of the previous chapter"
            case .currentChapterSoFar: return "the recent part of the current chapter"
            case .lastTenMinutes: return "the last couple of minutes before the current playback position"
            case .bookSoFar: return "the recent local context near the current playback position"
            }
        }
    }
}

enum BookTranscriptStatus: String, Codable, Sendable {
    case missing
    case ready
    case stale
    case generating
    case failed
}

enum BookContextSource: String, Codable, Sendable {
    case audiobookTranscript
    case ebookText
}

struct TranscriptSourceFile: Codable, Equatable, Sendable {
    let path: String
    let byteCount: Int64
    let modificationTime: TimeInterval
}

struct TranscriptSourceFingerprint: Codable, Equatable, Sendable {
    let version: Int
    let localeIdentifier: String
    let duration: TimeInterval
    let files: [TranscriptSourceFile]
}

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let bookStableId: String
    let chapterId: String?
    let trackIndex: Int
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let confidence: Double?
    let isFinal: Bool

    var duration: TimeInterval {
        max(0, endTime - startTime)
    }
}

struct BookTranscriptManifest: Codable, Equatable, Sendable {
    let bookStableId: String
    var status: BookTranscriptStatus
    var localeIdentifier: String
    var createdAt: Date
    var updatedAt: Date
    var duration: TimeInterval
    var segmentCount: Int
    var sourceFingerprint: TranscriptSourceFingerprint?
    var failureMessage: String?
}

struct BookTranscript: Codable, Equatable, Sendable {
    var manifest: BookTranscriptManifest
    var segments: [TranscriptSegment]
}

struct EbookContextChunk: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let bookStableId: String
    let title: String?
    let href: String?
    let index: Int
    let startProgress: Double
    let endProgress: Double
    let text: String
}

struct EbookContextManifest: Codable, Equatable, Sendable {
    let bookStableId: String
    var status: BookTranscriptStatus
    var createdAt: Date
    var updatedAt: Date
    var chunkCount: Int
    var failureMessage: String?
}

struct EbookContext: Codable, Equatable, Sendable {
    var manifest: EbookContextManifest
    var chunks: [EbookContextChunk]
}

struct BookContextResult: Sendable {
    let scope: BookIntelligenceScope
    let source: BookContextSource
    let range: ClosedRange<TimeInterval>
    let text: String
    let segmentCount: Int

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LibrarianMessage: Identifiable, Codable, Equatable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    let id: UUID
    let role: Role
    let text: String
    let scope: BookIntelligenceScope?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        scope: BookIntelligenceScope? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.scope = scope
        self.createdAt = createdAt
    }
}
