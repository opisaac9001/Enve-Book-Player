import Foundation

enum PodcastAutoQueuePosition: String, Codable, CaseIterable, Identifiable {
    case off
    case next
    case last

    nonisolated var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .off: "Off"
        case .next: "Play Next"
        case .last: "End of Up Next"
        }
    }

    nonisolated var isEnabled: Bool { self != .off }
}

enum PodcastAutoQueueLimit: String, Codable, CaseIterable, Identifiable {
    case one
    case two
    case three
    case five
    case ten
    case last24Hours
    case last7Days
    case last14Days
    case last30Days
    case all

    nonisolated var id: String { rawValue }

    nonisolated var maxCount: Int? {
        switch self {
        case .one: 1
        case .two: 2
        case .three: 3
        case .five: 5
        case .ten: 10
        default: nil
        }
    }

    nonisolated var timeWindow: TimeInterval? {
        switch self {
        case .last24Hours: 24 * 60 * 60
        case .last7Days: 7 * 24 * 60 * 60
        case .last14Days: 14 * 24 * 60 * 60
        case .last30Days: 30 * 24 * 60 * 60
        default: nil
        }
    }

    nonisolated var title: String {
        switch self {
        case .one: "Latest Episode"
        case .two: "2 Latest Episodes"
        case .three: "3 Latest Episodes"
        case .five: "5 Latest Episodes"
        case .ten: "10 Latest Episodes"
        case .last24Hours: "Last 24 Hours"
        case .last7Days: "Last 7 Days"
        case .last14Days: "Last 14 Days"
        case .last30Days: "Last 30 Days"
        case .all: "All New Episodes"
        }
    }
}

struct PodcastAutoQueueSetting: Codable, Equatable {
    var position: PodcastAutoQueuePosition = .off
    var limit: PodcastAutoQueueLimit = .all
    var baselinePublishedAt: Date?
}
