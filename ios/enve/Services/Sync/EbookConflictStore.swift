import Foundation

struct EbookSyncConflict: Equatable, Identifiable {
    var id: String { bookStableId }

    let bookStableId: String
    let bookTitle: String
    let localProgress: Double
    let serverProgress: Double
    let serverLocator: String?
    let serverDate: Date
    let remoteSource: String
}

@MainActor
@Observable
final class EbookConflictStore {
    static let shared = EbookConflictStore()

    private(set) var pending: [EbookSyncConflict] = []

    private init() {}

    func contains(stableId: String) -> Bool {
        pending.contains { $0.bookStableId == stableId }
    }

    func find(stableId: String) -> EbookSyncConflict? {
        pending.first { $0.bookStableId == stableId }
    }

    func add(_ conflict: EbookSyncConflict) {
        if let index = pending.firstIndex(where: { $0.bookStableId == conflict.bookStableId }) {
            if conflict.serverDate >= pending[index].serverDate { pending[index] = conflict }
            return
        }
        pending.append(conflict)
    }

    @discardableResult
    func remove(stableId: String) -> EbookSyncConflict? {
        guard let idx = pending.firstIndex(where: { $0.bookStableId == stableId }) else { return nil }
        return pending.remove(at: idx)
    }

    func clear() {
        pending.removeAll()
    }
}
