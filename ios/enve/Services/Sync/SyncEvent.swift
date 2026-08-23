import Foundation

enum SyncEvent: Sendable {
    case pullStarted(bookId: String)
    case pullCompleted(bookId: String, applied: Bool)
    case pushStarted(bookId: String)
    case pushCompleted(bookId: String)
    case pushFailed(bookId: String, error: String, retryable: Bool)
    case conflictDetected(bookId: String, localProgress: Double, remoteProgress: Double, remoteSource: String)
}
