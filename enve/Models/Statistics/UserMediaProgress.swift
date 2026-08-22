import Foundation

struct UserMediaProgress: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let libraryItemId: String
    let providerId: UUID
    let episodeId: String?
    let currentTime: TimeInterval
    let progress: Double
    let isFinished: Bool
    let duration: TimeInterval
    let lastUpdate: Date
    let ebookProgress: Double?

    nonisolated var uniqueId: String {
        if let episodeId = episodeId {
            return "\(providerId)_\(libraryItemId)-\(episodeId)"
        }
        return "\(providerId)_\(libraryItemId)"
    }

    nonisolated var progressPercent: Int {
        Int((progress * 100).rounded())
    }

    nonisolated var timeRemaining: TimeInterval {
        duration - currentTime
    }

    nonisolated var isRecent: Bool {
        let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 3600)
        return lastUpdate > sevenDaysAgo
    }
}
