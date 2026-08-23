import Foundation
import Observation

@MainActor
@Observable
final class WatchLibraryModel {
    static let shared = WatchLibraryModel()

    private(set) var snapshot = WatchLibrarySnapshot.empty
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    private static let snapshotURL = URL.documentsDirectory.appendingPathComponent("librarySnapshot.json")

    private init() {
        if let data = try? Data(contentsOf: Self.snapshotURL),
            let stored = try? JSONDecoder().decode(WatchLibrarySnapshot.self, from: data)
        {
            snapshot = stored
        }
    }

    func refreshIfStale() async {
        guard Date().timeIntervalSince(snapshot.generatedAt) > 120 else { return }
        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let fresh = try await PhoneLink.shared.request(.requestLibrary, EmptyPayload(), as: WatchLibrarySnapshot.self)
            snapshot = fresh
            lastError = nil
            if let data = try? JSONEncoder().encode(fresh) {
                try? data.write(to: Self.snapshotURL, options: .atomic)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func search(_ query: String) async throws -> [WatchBookSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let results = try await PhoneLink.shared.request(.requestSearch, WatchSearchRequest(query: trimmed), as: WatchSearchResults.self)
        return results.items
    }

    func summary(for stableId: String) -> WatchBookSummary? {
        snapshot.continueItems.first { $0.stableId == stableId }
            ?? snapshot.recentItems.first { $0.stableId == stableId }
            ?? snapshot.podcastItems.first { $0.stableId == stableId }
    }
}
