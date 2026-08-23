import Foundation

public enum MetadataProvider: String, CaseIterable, Identifiable {
    case iTunes = "iTunes"
    case audiobookshelf = "AudioBookshelf"
    case enveSearch = "Enve Search"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .iTunes:
            return "iTunes (Apple Books)"
        case .audiobookshelf:
            return "AudioBookshelf Server"
        case .enveSearch:
            return "Enve Search"
        }
    }

    public var description: String {
        switch self {
        case .iTunes:
            return "Free • Slow (rate limited) • Good quality"
        case .audiobookshelf:
            return "Free • Fast • Search via your ABS server"
        case .enveSearch:
            return "Free • Standalone • Rich audiobook metadata"
        }
    }

    public var icon: String {
        switch self {
        case .iTunes:
            return "applelogo"
        case .audiobookshelf:
            return "server.rack"
        case .enveSearch:
            return "magnifyingglass.circle.fill"
        }
    }

    public var requiresSubscription: Bool {
        false
    }

    public var requiresBackend: Bool {
        self == .audiobookshelf
    }

    public static func getDefaultProvider() -> MetadataProvider {
        return .enveSearch
    }
}
