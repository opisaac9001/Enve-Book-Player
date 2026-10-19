import Foundation

enum GrimmoryRemoteSort: String, Sendable {
    case addedOn
    case lastReadTime
    case title
}

struct GrimmoryRemotePage: Sendable {
    let books: [Book]
    let totalCount: Int
}

struct GrimmoryCatalogImportBatch {
    let pages: [Int]
    let books: [Book]
    let loadedSoFar: Int
    let totalCount: Int
}

final class GrimmoryCatalogImportSession {
    let libraryId: String
    let totalPages: Int
    let totalElements: Int
    var checkpoint: GrimmoryCatalogCheckpoint
    var seenIdentities: [String: String] = [:]
    var isComplete = true

    var completedSnapshot: Bool { isComplete }

    var reconciliation: ReconciliationStart? {
        guard let generation = checkpoint.reconciliationGeneration,
            let existingCount = checkpoint.existingCountBefore
        else { return nil }
        return ReconciliationStart(generation: generation, existingCount: existingCount)
    }

    init(libraryId: String, checkpoint: GrimmoryCatalogCheckpoint, isComplete: Bool = true) {
        self.libraryId = libraryId
        totalPages = checkpoint.totalPages
        totalElements = checkpoint.totalElements
        self.checkpoint = checkpoint
        self.isComplete = isComplete
    }
}

struct BookloreTierPreference {
    enum Tier: String {
        // Older builds persisted this tier after probing `/api/v1/app/libraries`.
        case komga
        case legacy
    }

    private let defaults: UserDefaults
    private let tierKey: String
    private let probeKey: String

    init(connectionId: UUID, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tierKey = "BookloreTier-\(connectionId.uuidString)"
        probeKey = "BookloreTierProbeDate-\(connectionId.uuidString)"
    }

    var restored: Tier? {
        defaults.string(forKey: tierKey).flatMap(Tier.init(rawValue:))
    }

    func store(_ tier: Tier) {
        defaults.set(tier.rawValue, forKey: tierKey)
    }

    func clear() {
        defaults.removeObject(forKey: tierKey)
        defaults.removeObject(forKey: probeKey)
    }

    func consumeUpgradeProbe(now: Date = Date(), interval: TimeInterval = 86_400) -> Bool {
        let lastProbe = defaults.object(forKey: probeKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(lastProbe) > interval else { return false }
        defaults.set(now, forKey: probeKey)
        return true
    }
}
