import Combine
import Foundation
import Logging

enum KeepNextOfflinePolicy {
    nonisolated static func seriesCandidates(current: Book, books: [Book]) -> [Book] {
        guard let series = normalizedSeries(current.series) else { return [] }

        let ordered =
            books
            .filter {
                $0.providerId == current.providerId
                    && $0.libraryId == current.libraryId
                    && $0.mediaType == .audiobook
                    && !$0.isPodcastEpisode
                    && normalizedSeries($0.series) == series
            }
            .sorted { lhs, rhs in
                let left = BookSortKeys.seriesNumber(lhs.seriesSequence)
                let right = BookSortKeys.seriesNumber(rhs.seriesSequence)
                if left != right { return left < right }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }

        return candidates(after: current, in: ordered)
    }

    nonisolated static func podcastCandidates(
        current: Book,
        episodes: [Book],
        newestFirst: Bool
    ) -> [Book] {
        let ordered = episodes.sorted { lhs, rhs in
            let left = lhs.addedAt ?? .distantPast
            let right = rhs.addedAt ?? .distantPast
            if left != right { return newestFirst ? left > right : left < right }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        return candidates(after: current, in: ordered)
    }

    nonisolated static func downloadsNeeded(
        from candidates: [Book],
        targetCount: Int,
        isKeptOffline: (Book) -> Bool
    ) -> [Book] {
        let target = max(1, targetCount)
        return candidates.prefix(target).filter { !isKeptOffline($0) }
    }

    nonisolated static func matches(_ lhs: Book, _ rhs: Book) -> Bool {
        if let leftEpisode = lhs.episodeId, let rightEpisode = rhs.episodeId {
            return leftEpisode == rightEpisode
        }
        return lhs.stableId == rhs.stableId
    }

    nonisolated private static func candidates(after current: Book, in ordered: [Book]) -> [Book] {
        guard let index = ordered.firstIndex(where: { matches($0, current) }) else { return [] }
        return ordered.dropFirst(index + 1).filter { !$0.isCompleted }
    }

    nonisolated private static func normalizedSeries(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

@MainActor
final class KeepNextOfflineService {
    static let allowedCounts = [1, 2, 3, 5, 10]

    private let downloads: DownloadsEngine
    private let appState: AppState
    private let playback: any PlaybackControlling
    private var cancellables: Set<AnyCancellable> = []
    private var reconcileTask: Task<Void, Never>?

    init(
        downloads: DownloadsEngine,
        appState: AppState = .shared,
        playback: any PlaybackControlling = ActivePlayback.controller
    ) {
        self.downloads = downloads
        self.appState = appState
        self.playback = playback

        playback.snapshots
            .map { $0.currentBook?.stableId }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleReconcile() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .preferencesDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleReconcile() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .bookStoreDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleReconcile() }
            .store(in: &cancellables)
    }

    func reconcile() {
        scheduleReconcile()
    }

    private func scheduleReconcile() {
        reconcileTask?.cancel()
        reconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await reconcileCurrentItem()
        }
    }

    private func reconcileCurrentItem() async {
        let preferences = LibraryDisplayPreferencesStore.shared.loadPreferences()
        guard preferences.keepNextItemsOfflineEnabled,
            downloads.isNetworkAvailable,
            !downloads.isCellularWithDownloadsDisabled,
            let current = playback.snapshot.currentBook,
            current.mediaType == .audiobook,
            downloads.isAudiobookDownloaded(current)
        else {
            return
        }

        let candidates: [Book]
        if current.isPodcastEpisode {
            candidates = await podcastCandidates(for: current)
        } else {
            let books = await appState.bookStore.allBooks()
            guard !Task.isCancelled else { return }
            candidates = KeepNextOfflinePolicy.seriesCandidates(current: current, books: books)
        }

        let missing = KeepNextOfflinePolicy.downloadsNeeded(
            from: candidates,
            targetCount: preferences.keepNextItemsOfflineCount,
            isKeptOffline: isKeptOffline
        )
        guard !missing.isEmpty else { return }

        AppLogger.network.debug(
            "Keeping \(missing.count) upcoming item(s) offline after bookDiagnosticID=\(DiagnosticLogSanitizer.identifier(for: current.stableId))"
        )
        for book in missing {
            Task { @MainActor [downloads] in
                await downloads.download(book)
            }
        }
    }

    private func podcastCandidates(for current: Book) async -> [Book] {
        #if os(tvOS)
        return []
        #else
        await PodcastsModel.shared.loadIfNeeded()
        guard !Task.isCancelled else { return [] }

        let parentKey = current.podcastLibraryItemId
        guard
            let show = PodcastsModel.shared.allShows.first(where: { show in
                (parentKey != nil && (show.feedURL ?? show.id) == parentKey)
                    || show.episodes.contains(where: { KeepNextOfflinePolicy.matches($0, current) })
            })
        else {
            return []
        }

        let newestFirst = UserDefaults.standard.object(forKey: "imagine.podcasts.show.newestFirst") as? Bool ?? true
        return KeepNextOfflinePolicy.podcastCandidates(
            current: current,
            episodes: show.episodes,
            newestFirst: newestFirst
        )
        #endif
    }

    private func isKeptOffline(_ book: Book) -> Bool {
        downloads.isAudiobookDownloaded(book)
            || downloads.mostRelevantTask(for: book)?.isActive == true
    }
}
