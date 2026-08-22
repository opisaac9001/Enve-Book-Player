import Foundation

enum BookQuery: Hashable, Sendable {

    case matching(collectionId: String, payload: SmartCollection)

    case inSeries(String)

    case mediaType(String)

    case sourceMediaType(source: String, mediaType: String)

    case library(libraryId: String, providerId: UUID)

    case continueListening(limit: Int)
    case continueReading(limit: Int)

    case recent(limit: Int)
    case recentEbooks(limit: Int)
    case downloadedEbooks(limit: Int)

    case search(query: String, limit: Int)

    static func == (lhs: BookQuery, rhs: BookQuery) -> Bool {
        switch (lhs, rhs) {
        case (.matching(let aId, _), .matching(let bId, _)):
            return aId == bId
        case (.inSeries(let a), .inSeries(let b)):
            return a == b
        case (.mediaType(let a), .mediaType(let b)):
            return a == b
        case (.sourceMediaType(let a1, let a2), .sourceMediaType(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.library(let a1, let a2), .library(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.continueListening(let a), .continueListening(let b)):
            return a == b
        case (.continueReading(let a), .continueReading(let b)):
            return a == b
        case (.recent(let a), .recent(let b)):
            return a == b
        case (.recentEbooks(let a), .recentEbooks(let b)):
            return a == b
        case (.downloadedEbooks(let a), .downloadedEbooks(let b)):
            return a == b
        case (.search(let a1, let a2), .search(let b1, let b2)):
            return a1 == b1 && a2 == b2
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .matching(let id, _):
            hasher.combine(0); hasher.combine(id)
        case .inSeries(let n):
            hasher.combine(1); hasher.combine(n)
        case .mediaType(let mt):
            hasher.combine(2); hasher.combine(mt)
        case .sourceMediaType(let s, let mt):
            hasher.combine(3); hasher.combine(s); hasher.combine(mt)
        case .library(let lib, let pid):
            hasher.combine(4); hasher.combine(lib); hasher.combine(pid)
        case .continueListening(let l):
            hasher.combine(5); hasher.combine(l)
        case .continueReading(let l):
            hasher.combine(6); hasher.combine(l)
        case .recent(let l):
            hasher.combine(7); hasher.combine(l)
        case .recentEbooks(let l):
            hasher.combine(8); hasher.combine(l)
        case .downloadedEbooks(let l):
            hasher.combine(9); hasher.combine(l)
        case .search(let q, let l):
            hasher.combine(10); hasher.combine(q); hasher.combine(l)
        }
    }
}
