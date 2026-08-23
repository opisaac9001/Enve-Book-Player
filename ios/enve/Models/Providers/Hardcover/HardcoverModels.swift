import Foundation

public struct FlexibleContributors: Codable, Hashable, Sendable {
    public let value: String?

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let arr = try? container.decode([[String: String]].self) {

            let names = arr.compactMap { $0["name"] ?? $0["author"] }
            value = names.isEmpty ? nil : names.joined(separator: ", ")
        } else if let arr = try? container.decode([String].self) {
            value = arr.isEmpty ? nil : arr.joined(separator: ", ")
        } else if let arr = try? container.decode([ContributorEntry].self) {
            let names = arr.compactMap(\.author?.name)
            value = names.isEmpty ? nil : names.joined(separator: ", ")
        } else {
            value = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public init(_ string: String?) {
        self.value = string
    }

    private struct ContributorEntry: Decodable {
        let author: AuthorRef?
        struct AuthorRef: Decodable {
            let name: String?
        }
    }
}

public struct HardcoverUserProfile: Codable, Identifiable, Sendable {
    public let id: Int
    public let username: String
    public let bio: String?
    public let image: HardcoverImage?
    public let flair: String?
    public let booksCount: Int?
    public let followingCount: Int?
    public let followersCount: Int?

    public var flairs: [String] {
        flair?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    }

    public var avatarURL: URL? {
        guard let urlString = image?.url, !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }
}

public struct HardcoverImage: Codable, Sendable {
    public let url: String?
}

public struct HardcoverBook: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let description: String?
    public let releaseYear: Int?
    public let slug: String?
    public let image: HardcoverImage?
    public let cachedContributors: FlexibleContributors?
    public let usersCount: Int?

    public var imageURL: URL? {
        guard let urlString = image?.url, !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }

    public var authorDisplay: String {
        cachedContributors?.value ?? "Unknown Author"
    }

    public static func == (lhs: HardcoverBook, rhs: HardcoverBook) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public struct HardcoverEdition: Codable, Identifiable, Sendable {
    public let id: Int
    public let title: String?
    public let isbn10: String?
    public let isbn13: String?
    public let pages: Int?
    public let audioSeconds: Int?
    public let readingFormatId: Int?
    public let editionFormat: String?
    public let publisher: HardcoverPublisher?
    public let image: HardcoverImage?
    public let releaseDate: String?
    public let usersCount: Int?

    public var isAudiobook: Bool {
        readingFormatId == 2 || (audioSeconds ?? 0) > 0
    }

    public var totalMinutes: Int {
        (audioSeconds ?? 0) / 60
    }

    public var displayInfo: String {
        if isAudiobook {
            let hours = totalMinutes / 60
            let mins = totalMinutes % 60
            return hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
        }
        if let pages, pages > 0 {
            return "\(pages) pages"
        }
        return ""
    }
}

public struct HardcoverPublisher: Codable, Sendable {
    public let name: String?
}

public enum HardcoverReadingStatus: Int, CaseIterable, Codable, Sendable {
    case wantToRead = 1
    case currentlyReading = 2
    case finished = 3
    case didNotFinish = 5

    public var displayName: String {
        switch self {
        case .wantToRead: return "Want to Read"
        case .currentlyReading: return "Currently Reading"
        case .finished: return "Finished"
        case .didNotFinish: return "Did Not Finish"
        }
    }

    public var iconName: String {
        switch self {
        case .wantToRead: return "bookmark"
        case .currentlyReading: return "book.fill"
        case .finished: return "checkmark.circle.fill"
        case .didNotFinish: return "xmark.circle"
        }
    }

    public var tintColor: String {
        switch self {
        case .wantToRead: return "blue"
        case .currentlyReading: return "green"
        case .finished: return "orange"
        case .didNotFinish: return "gray"
        }
    }
}

public struct HardcoverUserBook: Codable, Identifiable, Sendable {
    public let id: Int
    public let bookId: Int
    public let statusId: Int
    public let editionId: Int?
    public let rating: Double?
    public let review: String?
    public let privacySettingId: Int?
    public let book: HardcoverBook?
    public let edition: HardcoverEdition?
    public let userBookReads: [HardcoverUserBookRead]?

    public var readingStatus: HardcoverReadingStatus {
        HardcoverReadingStatus(rawValue: statusId) ?? .wantToRead
    }

    public var currentRead: HardcoverUserBookRead? {
        userBookReads?.first
    }

    public var progress: Double {
        guard let read = currentRead,
            let pages = read.progressPages,
            let total = edition?.pages, total > 0
        else { return 0 }
        return Double(pages) / Double(total)
    }
}

public struct HardcoverUserBookRead: Codable, Identifiable, Sendable {
    public let id: Int
    public let startedAt: String?
    public let finishedAt: String?
    public let progressPages: Int?
    public let progressSeconds: Int?
    public let editionId: Int?

    public var startDate: Date? {
        guard let str = startedAt else { return nil }
        return HardcoverDateFormatter.parseDate(str)
    }

    public var finishDate: Date? {
        guard let str = finishedAt else { return nil }
        return HardcoverDateFormatter.parseDate(str)
    }
}

public struct HardcoverFeedActivity: Identifiable, Sendable {
    public let id: Int
    public let userId: Int
    public let event: String
    public let createdAt: String
    public let username: String
    public let userImageURL: String?
    public let bookId: Int?
    public let bookTitle: String?
    public let bookImageURL: String?
    public let authorName: String?
    public let rating: Double?
    public let statusId: Int?
    public let progress: Int?
    public let reviewText: String?

    public var actionText: String {
        switch event {
        case "StatusUpdate":
            if let status = statusId.flatMap({ HardcoverReadingStatus(rawValue: $0) }) {
                switch status {
                case .wantToRead: return "wants to read"
                case .currentlyReading: return "started reading"
                case .finished: return "finished"
                case .didNotFinish: return "did not finish"
                }
            }
            return "updated"
        case "ReviewActivity":
            return "reviewed"
        case "RatingActivity":
            if let r = rating { return "rated \(String(format: "%.1f", r))★" }
            return "rated"
        case "ProgressActivity":
            if let p = progress { return "is \(p)% done with" }
            return "updated progress on"
        default:
            return "updated"
        }
    }

    public var actionIcon: String {
        switch event {
        case "StatusUpdate":
            return statusId.flatMap({ HardcoverReadingStatus(rawValue: $0) })?.iconName ?? "book"
        case "ReviewActivity": return "text.quote"
        case "RatingActivity": return "star.fill"
        case "ProgressActivity": return "chart.bar.fill"
        default: return "book"
        }
    }

    public var timeAgo: String {
        guard let date = HardcoverDateFormatter.parseISO8601(createdAt) else {
            return createdAt
        }
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        if interval < 604800 { return "\(Int(interval / 86400))d ago" }
        return "\(Int(interval / 604800))w ago"
    }
}

public struct HardcoverUserList: Codable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let description: String?
    public let slug: String?
    public let booksCount: Int
    public let likesCount: Int?
    public let isPublic: Bool

    public init(
        id: Int,
        name: String,
        description: String? = nil,
        slug: String? = nil,
        booksCount: Int = 0,
        likesCount: Int? = nil,
        isPublic: Bool = true
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.slug = slug
        self.booksCount = booksCount
        self.likesCount = likesCount
        self.isPublic = isPublic
    }
}

public struct HardcoverListBook: Codable, Identifiable, Sendable {
    public let id: Int
    public let bookId: Int
    public let title: String
    public let author: String?
    public let coverUrl: String?
}

public struct HardcoverTrendingBook: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
    public let author: String?
    public let coverImageUrl: String?
    public let usersCount: Int

    public var imageURL: URL? {
        guard let urlString = coverImageUrl, !urlString.isEmpty else { return nil }
        return URL(string: urlString)
    }
}

public struct HardcoverUserSearchResult: Identifiable, Sendable {
    public let id: Int
    public let username: String
    public let name: String?
    public let imageURL: String?
    public let flair: String?
}

public struct HardcoverReview: Identifiable, Sendable {
    public let id: Int
    public let userId: Int
    public let username: String
    public let userImageURL: String?
    public let rating: Double?
    public let reviewText: String?
    public let createdAt: String?
    public let hasReview: Bool

    public var timeAgo: String {
        guard let str = createdAt, let date = HardcoverDateFormatter.parseISO8601(str) else { return "" }
        let interval = Date().timeIntervalSince(date)
        if interval < 86400 { return "today" }
        if interval < 604800 { return "\(Int(interval / 86400))d ago" }
        if interval < 2_592_000 { return "\(Int(interval / 604800))w ago" }
        return "\(Int(interval / 2_592_000))mo ago"
    }
}

public struct HardcoverUserStats: Sendable {
    public let booksRead: Int
    public let pagesRead: Int
    public let authorsRead: Int
    public let reviewsWritten: Int
    public let hoursListened: Double
    public let averageRating: Double?

    public init(
        booksRead: Int = 0,
        pagesRead: Int = 0,
        authorsRead: Int = 0,
        reviewsWritten: Int = 0,
        hoursListened: Double = 0,
        averageRating: Double? = nil
    ) {
        self.booksRead = booksRead
        self.pagesRead = pagesRead
        self.authorsRead = authorsRead
        self.reviewsWritten = reviewsWritten
        self.hoursListened = hoursListened
        self.averageRating = averageRating
    }
}

public struct HardcoverFriend: Identifiable, Sendable {
    public let id: Int
    public let username: String
    public let imageURL: String?
    public let flair: String?
}

public struct HardcoverFinishedBookEntry: Identifiable, Hashable, Sendable {
    public let id: Int
    public let bookId: Int
    public let userBookId: Int
    public let title: String
    public let author: String
    public let rating: Double?
    public let finishedAt: Date?
    public let coverImageUrl: String?

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum HardcoverDateFormatter {
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func parseISO8601(_ string: String) -> Date? {
        iso8601.date(from: string) ?? iso8601NoFraction.date(from: string) ?? parseDate(string)
    }

    public static func parseDate(_ string: String) -> Date? {
        dateOnly.date(from: string)
    }

    public static func todayString() -> String {
        dateOnly.string(from: Date())
    }
}
