import Foundation

protocol ProgressSyncProtocol: Sendable {
    var sourceType: ListeningSourceType { get }

    func fetchAllProgress() async throws -> [ServerBookProgress]

    func fetchProgress(serverItemId: String) async throws -> ServerBookProgress?

    func reportProgress(serverItemId: String, position: TimeInterval, duration: TimeInterval, isFinished: Bool) async throws

    func testConnection() async throws -> Bool
}

enum ProgressSyncError: LocalizedError {
    case notAuthenticated
    case serverUnreachable
    case invalidResponse
    case noBackendConfigured
    case itemNotFound
    case syncFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "Not authenticated with server"
        case .serverUnreachable:
            return "Cannot reach server"
        case .invalidResponse:
            return "Invalid response from server"
        case .noBackendConfigured:
            return "No backend configured"
        case .itemNotFound:
            return "Item not found on server"
        case .syncFailed(let message):
            return "Sync failed: \(message)"
        }
    }
}
