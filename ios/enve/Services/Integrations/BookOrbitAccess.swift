import Foundation

@MainActor
enum BookOrbitAccess {
    static var connections: [ServerConnection] {
        AppState.shared.providerConnections.connections
            .filter { $0.type == .bookOrbit && $0.isConnected && !$0.isArchived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static var isAvailable: Bool { !connections.isEmpty }

    static func provider(_ connectionId: UUID) -> BookOrbitProvider? {
        AppState.shared.getProvider(connectionId) as? BookOrbitProvider
    }

    static func provider(for book: Book) -> BookOrbitProvider? {
        guard book.source == .bookOrbit else { return nil }
        return provider(book.providerId)
    }

    static func localBooks(connectionId: UUID, remoteIds: [Int]) async -> [Int: Book] {
        guard !remoteIds.isEmpty else { return [:] }
        let uniqueIds = Set(remoteIds.map { "\(connectionId)_\($0)" })
        let found = await AppState.shared.bookStore.booksByAnyIds(uniqueIds)
        var result: [Int: Book] = [:]
        for book in found.values {
            if let remoteId = Int(book.id), book.providerId == connectionId {
                result[remoteId] = book
            }
        }
        return result
    }

    static func message(for error: Error) -> String {
        if let providerError = error as? ProviderError {
            return providerError.errorDescription ?? "BookOrbit didn't answer."
        }
        return error.localizedDescription
    }
}
