import Foundation

enum ReaderInitialLocationPolicy {
    enum StoredStep: Equatable {
        case overlayRestore
        case progressLocator
        case snippetSearch
        case storedLocator
    }

    // Allow one second of clock skew before the book record's update.
    static func bridgeCheckpointIsCurrent(observedAt: Date?, bookLastUpdate: Date) -> Bool {
        guard let observedAt else { return false }
        return observedAt.addingTimeInterval(1) >= bookLastUpdate
    }

    static func acceptsRawEngineLocator(canonicalProgress: Double, rawProgress: Double) -> Bool {
        canonicalProgress <= rawProgress + 0.02
    }

    static func isSnippetSearchable(_ highlight: String?) -> Bool {
        guard let highlight else { return false }
        return highlight.count >= 8
    }

    static func storedRanking(
        isReadAloudLike: Bool,
        syncedProgress: Double,
        hasProgressLocator: Bool,
        storedProgress: Double?,
        highlight: String?
    ) -> [StoredStep] {
        guard !isReadAloudLike else { return [.overlayRestore] }
        guard let storedProgress else { return hasProgressLocator ? [.progressLocator] : [] }

        if hasProgressLocator, syncedProgress > 0.001, syncedProgress > storedProgress + 0.02 {
            return [.progressLocator]
        }

        var ranking: [StoredStep] = []
        if isSnippetSearchable(highlight) { ranking.append(.snippetSearch) }
        if hasProgressLocator { ranking.append(.progressLocator) }
        ranking.append(.storedLocator)
        return ranking
    }
}
