import Foundation

struct StorytellerPermissions {
    let canListBooks: Bool
    let canProcessBooks: Bool
}

struct StorytellerShelfBook: Codable {
    let bookUuid: String
    let position: Int?
}

struct StorytellerShelf: Decodable, Identifiable {
    let uuid: String
    let userId: String?
    let name: String
    let description: String?
    let orderBy: String
    let orderDirection: String
    let limitCount: Int?
    let icon: String?
    let color: String?
    let createdAt: String?
    let updatedAt: String?
    let books: [StorytellerShelfBook]
    let hasFilter: Bool

    var id: String { uuid }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        userId = container.decodeLenient(String.self, forKey: .userId)
        name = container.decodeLenient(String.self, forKey: .name) ?? ""
        description = container.decodeLenient(String.self, forKey: .description)
        orderBy = container.decodeLenient(String.self, forKey: .orderBy) ?? "createdAt"
        orderDirection = container.decodeLenient(String.self, forKey: .orderDirection) ?? "desc"
        limitCount = container.decodeLenient(Int.self, forKey: .limitCount)
        icon = container.decodeLenient(String.self, forKey: .icon)
        color = container.decodeLenient(String.self, forKey: .color)
        createdAt = container.decodeLenient(String.self, forKey: .createdAt)
        updatedAt = container.decodeLenient(String.self, forKey: .updatedAt)
        books = container.decodeLenient([StorytellerShelfBook].self, forKey: .books) ?? []
        hasFilter = container.contains(.filter)
            && ((try? container.decodeNil(forKey: .filter)) == false)
    }

    private enum CodingKeys: String, CodingKey {
        case uuid, userId, name, description, filter, orderBy, orderDirection
        case limitCount, icon, color, createdAt, updatedAt, books
    }
}

struct StorytellerManagementBook: Identifiable, Hashable {
    let id: String
    let title: String
    let author: String?

    var searchText: String {
        "\(title) \(author ?? "")"
    }
}

struct StorytellerAlignmentSummary: Codable {
    let grade: String
    let score: Double?
    let chapters: Int
    let missingSentences: Int
    let mutedChapters: Int
    let failedChapters: Int
    let unalignedAudio: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        grade = container.decodeLenient(String.self, forKey: .grade) ?? "—"
        score = container.decodeLenient(Double.self, forKey: .score)
        chapters = container.decodeLenient(Int.self, forKey: .chapters) ?? 0
        missingSentences = container.decodeLenient(Int.self, forKey: .missingSentences) ?? 0
        mutedChapters = container.decodeLenient(Int.self, forKey: .mutedChapters) ?? 0
        failedChapters = container.decodeLenient(Int.self, forKey: .failedChapters) ?? 0
        unalignedAudio = container.decodeLenient(Int.self, forKey: .unalignedAudio) ?? 0
    }
}

struct StorytellerAlignmentFacets: Codable {
    let grades: [String: Int]
    let total: Int
    let muted: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        grades = container.decodeLenient([String: Int].self, forKey: .grades) ?? [:]
        total = container.decodeLenient(Int.self, forKey: .total) ?? 0
        muted = container.decodeLenient(Int.self, forKey: .muted) ?? 0
    }
}

struct StorytellerAlignmentFlag: Codable, Identifiable {
    let label: String
    let tone: String

    var id: String { "\(tone)\u{1F}\(label)" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        tone = try container.decode(String.self, forKey: .tone)
    }
}

struct StorytellerAlignmentChapter: Codable, Identifiable {
    let href: String
    let label: String
    let title: String?
    let chapterSentenceCount: Int
    let alignedSentenceCount: Int
    let coverage: Double?
    let delta: Double
    let deltaPct: Double
    let flagged: Bool
    let flags: [StorytellerAlignmentFlag]
    let markedOk: Bool
    let excludedFromScore: Bool

    var id: String { href }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        href = try container.decode(String.self, forKey: .href)
        label = container.decodeLenient(String.self, forKey: .label) ?? href
        title = container.decodeLenient(String.self, forKey: .title)
        chapterSentenceCount = container.decodeLenient(Int.self, forKey: .chapterSentenceCount) ?? 0
        alignedSentenceCount = container.decodeLenient(Int.self, forKey: .alignedSentenceCount) ?? 0
        coverage = container.decodeLenient(Double.self, forKey: .coverage)
        delta = container.decodeLenient(Double.self, forKey: .delta) ?? 0
        deltaPct = container.decodeLenient(Double.self, forKey: .deltaPct) ?? 0
        flagged = container.decodeLenient(Bool.self, forKey: .flagged) ?? false
        flags = container.decodeLenient([StorytellerAlignmentFlag].self, forKey: .flags) ?? []
        markedOk = container.decodeLenient(Bool.self, forKey: .markedOk) ?? false
        excludedFromScore = container.decodeLenient(Bool.self, forKey: .excludedFromScore) ?? false
    }
}

struct StorytellerUnalignedChapter: Codable, Identifiable {
    let href: String
    let label: String
    let reason: String
    let preview: String?
    let intended: Bool

    var id: String { href }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        href = try container.decode(String.self, forKey: .href)
        label = container.decodeLenient(String.self, forKey: .label) ?? href
        reason = container.decodeLenient(String.self, forKey: .reason) ?? "Unaligned"
        preview = container.decodeLenient(String.self, forKey: .preview)
        intended = container.decodeLenient(Bool.self, forKey: .intended) ?? false
    }
}

struct StorytellerUnalignedAudioFile: Codable, Identifiable {
    let filepath: String
    let title: String?
    let duration: Double?
    let transcription: String?
    let excluded: Bool

    var id: String { filepath }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        filepath = try container.decode(String.self, forKey: .filepath)
        title = container.decodeLenient(String.self, forKey: .title)
        duration = container.decodeLenient(Double.self, forKey: .duration)
        transcription = container.decodeLenient(String.self, forKey: .transcription)
        excluded = container.decodeLenient(Bool.self, forKey: .excluded) ?? false
    }
}

struct StorytellerAlignmentReport: Codable {
    let bookUuid: String
    let bookTitle: String?
    let reportUuid: String
    let createdAt: String?
    let summary: StorytellerAlignmentSummary
    let totalAudioDuration: Double
    let alignedAudioDuration: Double
    let totalSentences: Int
    let alignedSentences: Int
    let significantChapters: Int
    let chapters: [StorytellerAlignmentChapter]
    let unalignedChapters: [StorytellerUnalignedChapter]
    let unalignedAudioFiles: [StorytellerUnalignedAudioFile]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bookUuid = try container.decode(String.self, forKey: .bookUuid)
        bookTitle = container.decodeLenient(String.self, forKey: .bookTitle)
        reportUuid = try container.decode(String.self, forKey: .reportUuid)
        createdAt = container.decodeLenient(String.self, forKey: .createdAt)
        summary = try container.decode(StorytellerAlignmentSummary.self, forKey: .summary)
        totalAudioDuration = container.decodeLenient(Double.self, forKey: .totalAudioDuration) ?? 0
        alignedAudioDuration = container.decodeLenient(Double.self, forKey: .alignedAudioDuration) ?? 0
        totalSentences = container.decodeLenient(Int.self, forKey: .totalSentences) ?? 0
        alignedSentences = container.decodeLenient(Int.self, forKey: .alignedSentences) ?? 0
        significantChapters = container.decodeLenient(Int.self, forKey: .significantChapters) ?? 0
        chapters = container.decodeLenient([StorytellerAlignmentChapter].self, forKey: .chapters) ?? []
        unalignedChapters = container.decodeLenient([StorytellerUnalignedChapter].self, forKey: .unalignedChapters) ?? []
        unalignedAudioFiles = container.decodeLenient([StorytellerUnalignedAudioFile].self, forKey: .unalignedAudioFiles) ?? []
    }
}

enum StorytellerAlignmentRestartMode: String, CaseIterable {
    case continueExisting
    case sync
    case transcription
    case full

    var queryValue: String? {
        self == .continueExisting ? nil : rawValue
    }
}

struct StorytellerProcessingBook: Identifiable {
    let id: String
    let title: String
    let author: String?
    let readaloudStatus: String?
    let currentStage: String?
    let stageProgress: Double?
    let queuePosition: Int?
    let restartPending: Bool

    var isProcessing: Bool {
        let status = readaloudStatus?.uppercased()
        return status == "PROCESSING" || status == "QUEUED"
    }

    var statusLabel: String {
        if restartPending { return "Restart pending" }
        switch readaloudStatus?.uppercased() {
        case "PROCESSING":
            return currentStage.map(Self.stageLabel) ?? "Processing"
        case "QUEUED":
            return queuePosition.map { "Queued #\($0)" } ?? "Queued"
        case "ALIGNED": return "Aligned"
        case "ERROR": return "Error"
        case "STOPPED": return "Stopped"
        case let status?: return status.replacingOccurrences(of: "_", with: " ").capitalized
        case nil: return "Not started"
        }
    }

    private static func stageLabel(_ stage: String) -> String {
        switch stage.uppercased() {
        case "SPLIT_TRACKS": return "Splitting audio"
        case "TRANSCRIBE_CHAPTERS": return "Transcribing"
        case "SYNC_CHAPTERS": return "Syncing"
        default: return stage.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

enum StorytellerManagementError: LocalizedError {
    case unavailable
    case forbidden
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "This Storyteller server does not support this tool."
        case .forbidden: return "This account does not have permission to use this tool."
        case .rejected(let message): return message
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeLenient<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
        (try? decode(T.self, forKey: key)) ?? (try? decodeIfPresent(T.self, forKey: key))
    }
}
