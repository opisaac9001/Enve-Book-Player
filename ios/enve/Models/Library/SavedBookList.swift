import Foundation

nonisolated enum SavedBookList: String, Codable, CaseIterable, Identifiable, Sendable {
    case favorites
    case later

    var id: String { rawValue }
    var title: String { self == .favorites ? "Favorites" : "For Later" }
    var symbol: String { self == .favorites ? "heart.fill" : "bookmark.fill" }
}
