import Foundation

struct SmartCollection: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let description: String?
    let rules: SmartCollectionRuleGroup
    let iconName: String
    let color: String
    let isSystem: Bool
    let sortOrder: Int

    var parentID: String?
    var customCoverPath: String?
}

struct SmartCollectionRuleGroup: Codable, Hashable {
    let logicOperator: LogicOperator
    let rules: [SmartCollectionRule]
}

enum LogicOperator: String, Codable, CaseIterable {
    case and = "AND"
    case or = "OR"
}

struct SmartCollectionRule: Codable, Hashable {
    let field: SmartCollectionField
    let `operator`: SmartCollectionOperator
    let value: String
}

enum SmartCollectionField: String, Codable, CaseIterable {
    case author
    case narrator
    case genre
    case duration
    case progress
    case isFinished
    case isAbandoned
    case isDownloaded
    case dateAdded
    case lastPlayed
    case releaseYear

    var displayName: String {
        switch self {
        case .author: return "Author"
        case .narrator: return "Narrator"
        case .genre: return "Genre"
        case .duration: return "Duration"
        case .progress: return "Progress"
        case .isFinished: return "Finished Status"
        case .isAbandoned: return "Abandoned"
        case .isDownloaded: return "Downloaded"
        case .dateAdded: return "Date Added"
        case .lastPlayed: return "Last Played"
        case .releaseYear: return "Release Year"
        }
    }
}

enum SmartCollectionOperator: String, Codable, CaseIterable {
    case equals
    case notEquals
    case contains
    case greaterThan
    case lessThan
    case isTrue
    case isFalse

    var displayName: String {
        switch self {
        case .equals: return "equals"
        case .notEquals: return "does not equal"
        case .contains: return "contains"
        case .greaterThan: return "greater than"
        case .lessThan: return "less than"
        case .isTrue: return "is true"
        case .isFalse: return "is false"
        }
    }
}
