import Foundation

enum FamilyProfileRole: String, Codable {
    case adult
    case child
}

struct FamilyProfile: Identifiable, Codable, Equatable {
    nonisolated static let ownerID = "adult-default"

    let id: String
    var name: String
    let role: FamilyProfileRole

    nonisolated static func validID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) ||
                (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

enum FamilyProfileError: Error, Equatable {
    case invalidName
    case profileNotFound
    case invalidCatalog
}
