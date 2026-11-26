#if os(iOS)
import Foundation

struct ClubAccount: Codable, Equatable {
    let id: String
    let name: String
}

struct ClubCredentials: Codable {
    let account: ClubAccount
    let token: String
    var recoveryKey: String
}

struct ClubSummary: Decodable, Identifiable {
    let id: String
    let name: String
    let ownerID: String
    let currentTitle: String?
    let currentReadID: String?
    let currentAuthor: String?
    let nextCheckpoint: NextCheckpoint?

    struct NextCheckpoint: Decodable {
        let label: String
        let dueAt: Date?
    }
}

struct ClubDetails: Decodable {
    let id: String
    let name: String
    let ownerID: String
    let members: [ClubAccount]
    let reads: [ClubRead]
    let activity: [ClubActivity]
    let blockedIDs: [String]

    var currentRead: ClubRead? { reads.first { $0.closedAt == nil } }
    var history: [ClubRead] { reads.filter { $0.closedAt != nil } }
}

struct ClubRead: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let author: String?
    let series: String?
    let createdAt: Date
    let closedAt: Date?
}

struct ClubActivity: Decodable, Identifiable {
    let id: String
    let accountID: String?
    let memberName: String?
    let kind: String
    let label: String
    let createdAt: Date

    var description: String {
        let name = memberName ?? "A member"
        switch kind {
        case "readStarted": return "\(name) started \(label)"
        case "checkpoint": return "\(name) reached \(label)"
        case "pollClosed": return "\(name) closed the vote for \(label)"
        case "planChanged": return "\(name) updated the reading plan"
        default: return label
        }
    }
}

struct ClubCheckpoint: Decodable, Identifiable, Hashable {
    let id: String
    let label: String
    let chapterKey: String?
    let dueAt: Date?
    let trackPosition: Double?
    let sortOrder: Int
}

struct ClubCheckpointDraft: Encodable, Identifiable {
    var id = UUID()
    var label: String
    var chapterKey: String?
    var dueAt: Date?
    var trackPosition: Double?

    enum CodingKeys: String, CodingKey { case label, chapterKey, dueAt, trackPosition }
}

struct ClubReadDraft: Encodable {
    var title: String
    var author: String?
    var series: String?
    var checkpoints: [ClubCheckpointDraft]
    var pollID: String?
}

struct ClubSharing: Codable {
    let epoch: String?
    let presence: Bool
}

struct ClubPosition: Decodable {
    let accountID: String
    let fraction: Double
    let observedAt: Date
    let activeUntil: Date?
}

struct ClubCompletion: Decodable {
    let accountID: String
    let checkpointID: String
    let completedAt: Date
}

struct ClubReadDetails: Decodable {
    let read: ClubRead
    let checkpoints: [ClubCheckpoint]
    let progress: [ClubPosition]
    let completions: [ClubCompletion]
    let sharing: ClubSharing?
    let hostedCopy: ClubHostedCopy?

    func completed(by accountID: String) -> Set<String> {
        Set(completions.lazy.filter { $0.accountID == accountID }.map(\.checkpointID))
    }
}

struct ClubHostedCopy: Decodable {
    struct File: Decodable {
        let index: Int
        let name: String
        let bytes: Int64
        let contentType: String
    }

    let id: String
    let title: String
    let format: String
    let files: [File]
}

enum ClubHostedCopyDownloadProgress {
    case downloading(completed: Int, total: Int)
    case importing
}

struct ClubInvite: Decodable {
    let code: String
    let expiresAt: Date

    var displayCode: String { "\(code.prefix(5))-\(code.suffix(5))" }

    var shareText: String {
        if let url = ClubsAPI.inviteURL(code: code) {
            return "Join my Enve book club: \(url.absoluteString)\nInvite code: \(displayCode)"
        }
        return "Join my Enve book club with invite code \(displayCode)."
    }
}

struct ClubPost: Decodable, Identifiable {
    let id: String
    let authorID: String
    let authorName: String
    let parentID: String?
    let body: String
    let passage: String?
    let passageChapter: String?
    let createdAt: Date
    let reactions: [ClubReaction]
    let isSpoiler: Bool?
    let concealed: Bool?
}

struct ClubReaction: Decodable {
    let accountID: String
    let emoji: String

    static let choices = ["\u{2764}\u{FE0F}", "\u{1F602}", "\u{1F62E}", "\u{1F44F}", "\u{1F4DA}"]
}

struct ClubDiscussionLink: Decodable, Hashable {
    let clubID: String
    let readID: String
    let threadID: String
    let postID: String
}

struct ClubPosts: Decodable {
    let focusedPost: ClubPost?
    let posts: [ClubPost]
    let before: String?
    let archived: Bool
    let discussionTools: Bool?
    let prompt: ClubDiscussionPrompt?
}

struct ClubDiscussionPrompt: Decodable {
    let body: String
    let updatedAt: Date
}

struct ClubNomination: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let author: String?
    let accountID: String?
    let memberName: String?
    let createdAt: Date
}

struct ClubPoll: Decodable, Identifiable {
    let id: String
    let name: String
    let createdAt: Date
    let closesAt: Date?
    let closedAt: Date?
    let winnerID: String?
    let startedReadID: String?
    let optionIDs: [String]
    let votes: [ClubVote]

    var isAcceptingVotes: Bool { closedAt == nil && (closesAt.map { $0 > .now } ?? true) }

    var leaders: Set<String> {
        let counts = Dictionary(grouping: votes, by: \.nominationID).mapValues(\.count)
        let high = counts.values.max() ?? 0
        return Set(optionIDs.filter { counts[$0, default: 0] == high })
    }
}

struct ClubVote: Decodable, Identifiable {
    var id: String { accountID }
    let accountID: String
    let nominationID: String
    let memberName: String
}

struct ClubNextUp: Decodable {
    let nominations: [ClubNomination]
    let polls: [ClubPoll]
}

struct ClubCopy: Codable {
    let clubID: String
    let readID: String
    var bookID: String
    var sharing: ClubSharing?
    var checkpointEnds: [String: Double] = [:]
    var checkpointOrder: [String] = []
    var checkpointKeys: [String: String] = [:]
}

struct ClubProgressUpdate: Codable {
    let epoch: String
    let fraction: Double
    let observedAt: Date
    let active: Bool
}
#endif
