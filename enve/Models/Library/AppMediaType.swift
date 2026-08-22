import Foundation

public enum AppMediaType: String, Codable {
    case audiobook
    case podcast
    case ebook

    var displayName: String {
        switch self {
        case .audiobook: return "Audiobooks"
        case .ebook: return "Books"
        case .podcast: return "Podcasts"
        }
    }

    var icon: String {
        switch self {
        case .audiobook: return "headphones"
        case .ebook: return "text.book.closed.fill"
        case .podcast: return "antenna.radiowaves.left.and.right"
        }
    }
}
