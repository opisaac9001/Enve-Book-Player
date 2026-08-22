import Foundation

public struct HardcoverBookMatch: Codable, Identifiable {
    public let id: UUID
    public let localBookId: String
    public let hardcoverBookId: Int
    public let hardcoverUserBookId: Int?
    public let hardcoverEditionId: Int?
    public let editionPageCount: Int?
    public let matchedAt: Date
    public let matchType: MatchType

    public let localBookTitle: String?
    public let hardcoverBookTitle: String?

    public enum MatchType: String, Codable {
        case manual
        case automatic
    }

    public init(
        id: UUID = UUID(),
        localBookId: String,
        hardcoverBookId: Int,
        hardcoverUserBookId: Int? = nil,
        hardcoverEditionId: Int? = nil,
        editionPageCount: Int? = nil,
        matchedAt: Date = Date(),
        matchType: MatchType = .manual,
        localBookTitle: String? = nil,
        hardcoverBookTitle: String? = nil
    ) {
        self.id = id
        self.localBookId = localBookId
        self.hardcoverBookId = hardcoverBookId
        self.hardcoverUserBookId = hardcoverUserBookId
        self.hardcoverEditionId = hardcoverEditionId
        self.editionPageCount = editionPageCount
        self.matchedAt = matchedAt
        self.matchType = matchType
        self.localBookTitle = localBookTitle
        self.hardcoverBookTitle = hardcoverBookTitle
    }
}

public struct HardcoverMatchStorage: Codable {
    public var matches: [HardcoverBookMatch]
    public let version: String
    public let lastUpdated: Date

    init(matches: [HardcoverBookMatch] = [], version: String = "1.0", lastUpdated: Date = Date()) {
        self.matches = matches
        self.version = version
        self.lastUpdated = lastUpdated
    }
}
