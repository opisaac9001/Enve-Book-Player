import Foundation

enum ProgressSyncDomain: Sendable {
    case audiobook
    case ebook

    var usesEbookProgress: Bool {
        switch self {
        case .audiobook:
            return false
        case .ebook:
            return true
        }
    }
}

struct ProgressUpdate: Sendable {
    let book: Book
    let domain: ProgressSyncDomain
    let positionSeconds: TimeInterval
    let progress: Double
    let locator: String?
    let sourceEngine: ReaderEngineKind?
    let sessionId: String?
    let isFinished: Bool
    let timeListened: TimeInterval
    let playbackRate: Double
}

@MainActor
protocol SyncSink: AnyObject, Sendable {

    var id: String { get }

    var displayName: String { get }

    func isApplicable(to book: Book, domain: ProgressSyncDomain) -> Bool

    func pull(book: Book, domain: ProgressSyncDomain) async -> SyncSnapshot?

    func push(_ update: ProgressUpdate) async throws
}
