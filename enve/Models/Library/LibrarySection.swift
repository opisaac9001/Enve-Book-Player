import Foundation

struct LibrarySection: Identifiable, Codable, Equatable {
    let id: String
    let key: String
    let title: String
    let type: String
    let serverId: String?
    let backendId: String?

    var displayId: String { "\(backendId ?? "local")|\(type)|\(id)" }
}
