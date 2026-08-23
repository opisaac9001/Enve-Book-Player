import Foundation

struct LibraryImportProgress {
    let libraryId: String
    let libraryName: String
    var providerName: String = ""
    var loadedCount: Int
    var totalCount: Int?
    var isComplete: Bool
    var phase: Phase = .indexing
    var startTime: Date = Date()

    enum Phase: String {
        case connecting = "Connecting"
        case checkingForUpdates = "Checking for updates"
        case indexing = "Downloading library"
        case fetchingProgress = "Syncing progress"
        case enrichingMetadata = "Applying metadata"
        case fetchingSeries = "Loading series"
        case fetchingCollections = "Loading collections"
        case deduplicating = "Organizing library"
        case done = "Complete"
    }

    var displayText: String {
        switch phase {
        case .connecting:
            return "Connecting to \(providerName)..."
        case .checkingForUpdates:
            return "Checking \(libraryName) for changes..."
        case .indexing:
            if isComplete {
                return "\(loadedCount) books loaded"
            } else if let total = totalCount, total > 0 {
                let pct = Int(Double(loadedCount) / Double(total) * 100)
                return "\(loadedCount) of \(total) books (\(pct)%)\(etaString)"
            } else if loadedCount > 0 {
                return "\(loadedCount) books so far..."
            } else {
                return "Starting download..."
            }
        case .fetchingProgress:
            return "Syncing reading progress..."
        case .enrichingMetadata:
            return "Applying stored metadata..."
        case .fetchingSeries:
            return "Loading series & collections..."
        case .fetchingCollections:
            return "Loading collections..."
        case .deduplicating:
            if let total = totalCount, total > 0 {
                let pct = Int(Double(loadedCount) / Double(total) * 100)
                return "Grouping duplicates and versions (\(pct)%)"
            }
            return "Grouping duplicates and versions..."
        case .done:
            return "\(loadedCount) books ready"
        }
    }

    var headerText: String {
        if phase == .connecting {
            return "Connecting..."
        }
        if phase == .deduplicating {
            return "Organizing library"
        }
        return "Syncing \(libraryName)"
    }

    private var etaString: String {
        guard loadedCount > 0, let total = totalCount, total > loadedCount else { return "" }
        let elapsed = Date().timeIntervalSince(startTime)
        guard elapsed > 2 else { return "" }
        let rate = Double(loadedCount) / elapsed
        guard rate > 0 else { return "" }
        let remaining = Double(total - loadedCount) / rate
        if remaining < 5 { return " - almost done" }
        if remaining < 60 { return " - ~\(Int(remaining))s left" }
        let minutes = Int(remaining / 60)
        return " - ~\(minutes)m left"
    }

    var fraction: Double? {
        guard let total = totalCount, total > 0 else { return nil }
        return min(Double(loadedCount) / Double(total), 1.0)
    }
}
