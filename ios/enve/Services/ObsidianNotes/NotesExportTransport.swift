import Foundation

enum NotesExportError: Error, LocalizedError {
    case vaultNotConfigured
    case vaultBookmarkStale
    case vaultAccessDenied
    case templateError(String)
    case transportFailed(Error)

    var errorDescription: String? {
        switch self {
        case .vaultNotConfigured:
            return "No Obsidian vault folder is selected."
        case .vaultBookmarkStale:
            return "Access to the vault folder has expired. Reselect it in Settings."
        case .vaultAccessDenied:
            return "Enve doesn't have permission to write to the selected folder."
        case .templateError(let detail):
            return "Template error: \(detail)"
        case .transportFailed(let inner):
            return "Couldn't write notes: \(inner.localizedDescription)"
        }
    }
}

protocol NotesExportTransport: Sendable {

    func loadExisting(for bookStableId: String, filename: String) async throws -> String?

    func write(markdown: String, for bookStableId: String, filename: String) async throws
}
