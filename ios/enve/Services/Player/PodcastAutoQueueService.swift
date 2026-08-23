import Combine
import Foundation
import Logging
import UIKit

enum PodcastAutoQueuePolicy {
    nonisolated static func newEpisodes(
        from episodes: [Book],
        after baseline: Date,
        limit: PodcastAutoQueueLimit,
        now: Date
    ) -> [Book] {
        let cutoff = limit.timeWindow.map { now.addingTimeInterval(-$0) }
        return
            episodes
            .filter { episode in
                guard !episode.isCompleted, let publishedAt = episode.addedAt else { return false }
                guard publishedAt > baseline else { return false }
                if let cutoff { return publishedAt >= cutoff }
                return true
            }
            .sorted { ($0.addedAt ?? .distantPast) < ($1.addedAt ?? .distantPast) }
    }

    nonisolated static func newestSeenDate(in episodes: [Book], after baseline: Date) -> Date? {
        episodes.compactMap(\.addedAt).filter { $0 > baseline }.max()
    }

    nonisolated static func entriesToRemove(
        from entries: [PlaybackQueueEntry],
        groupKey: String,
        limit: PodcastAutoQueueLimit,
        now: Date
    ) -> [String] {
        let matching = entries.filter {
            $0.origin == .podcastAuto && $0.groupKey == groupKey && $0.book.addedAt != nil
        }

        if let window = limit.timeWindow {
            let cutoff = now.addingTimeInterval(-window)
            return
                matching
                .filter { ($0.book.addedAt ?? .distantPast) < cutoff }
                .map { $0.book.uniqueId }
        }

        guard let maxCount = limit.maxCount, matching.count > maxCount else { return [] }
        return
            matching
            .sorted { ($0.book.addedAt ?? .distantPast) > ($1.book.addedAt ?? .distantPast) }
            .dropFirst(maxCount)
            .map { $0.book.uniqueId }
    }
}

@MainActor
final class PodcastAutoQueueService {
    private static let refreshInterval: TimeInterval = 60 * 60

    private let queue: PlaybackQueueStore
    private var cancellables: Set<AnyCancellable> = []
    private var lastRefresh: Date?
    private var isRefreshing = false
    private var lastSettings: [String: PodcastAutoQueueSetting]

    init(queue: PlaybackQueueStore) {
        self.queue = queue
        self.lastSettings = LibraryDisplayPreferencesStore.shared.loadPreferences().podcastAutoQueueSettings

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refresh() }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .preferencesDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.preferencesChanged() }
            .store(in: &cancellables)

        Task { @MainActor [weak self] in await self?.refresh() }
    }

    func refresh(force: Bool = false) async {
        #if !os(tvOS)
        let settings = LibraryDisplayPreferencesStore.shared.loadPreferences().podcastAutoQueueSettings
        guard settings.values.contains(where: { $0.position.isEnabled }), !isRefreshing else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.refreshInterval {
            return
        }

        isRefreshing = true
        await PodcastsModel.shared.load()
        lastRefresh = Date()
        isRefreshing = false
        #endif
    }

    func reconcile(
        _ shows: [AudiobookshelfProvider.PodcastShow],
        now: Date = Date()
    ) {
        var preferences = LibraryDisplayPreferencesStore.shared.loadPreferences()
        let originalSettings = preferences.podcastAutoQueueSettings
        guard !originalSettings.isEmpty else { return }

        let showsByKey = shows.reduce(into: [String: AudiobookshelfProvider.PodcastShow]()) {
            $0[$1.feedURL ?? $1.id] = $1
        }
        var settings = originalSettings

        for (showKey, var setting) in originalSettings where setting.position.isEnabled {
            guard let baseline = setting.baselinePublishedAt else {
                setting.baselinePublishedAt = now
                settings[showKey] = setting
                continue
            }

            if let show = showsByKey[showKey] {
                enqueueNewEpisodes(
                    show.episodes,
                    showKey: showKey,
                    setting: setting,
                    baseline: baseline,
                    now: now
                )

                if let newestSeen = PodcastAutoQueuePolicy.newestSeenDate(
                    in: show.episodes,
                    after: baseline
                ) {
                    setting.baselinePublishedAt = newestSeen
                    settings[showKey] = setting
                }
            }

            enforceLimit(setting.limit, showKey: showKey, now: now)
        }

        guard settings != originalSettings else { return }
        preferences.podcastAutoQueueSettings = settings
        lastSettings = settings
        LibraryDisplayPreferencesStore.shared.savePreferences(preferences)
        Theme.currentPreferences = preferences
    }

    private func enqueueNewEpisodes(
        _ episodes: [Book],
        showKey: String,
        setting: PodcastAutoQueueSetting,
        baseline: Date,
        now: Date
    ) {
        let existingIDs = Set(queue.entries.map(\.id))
        let currentID = ActivePlayback.controller.snapshot.currentBook?.uniqueId
        let episodesToQueue = PodcastAutoQueuePolicy.newEpisodes(
            from: episodes,
            after: baseline,
            limit: setting.limit,
            now: now
        ).filter { $0.uniqueId != currentID && !existingIDs.contains($0.uniqueId) }

        switch setting.position {
        case .next:
            for episode in episodesToQueue.reversed() {
                queue.addNext(episode, origin: .podcastAuto, groupKey: showKey)
            }
        case .last:
            for episode in episodesToQueue {
                queue.addLast(episode, origin: .podcastAuto, groupKey: showKey)
            }
        case .off:
            return
        }

        if !episodesToQueue.isEmpty {
            AppLogger.player.info("Auto-queued \(episodesToQueue.count) new episode(s) for podcast \(showKey)")
        }
    }

    private func enforceLimit(_ limit: PodcastAutoQueueLimit, showKey: String, now: Date) {
        let ids = PodcastAutoQueuePolicy.entriesToRemove(
            from: queue.entries,
            groupKey: showKey,
            limit: limit,
            now: now
        )
        for id in ids {
            queue.remove(bookID: id)
        }
        if !ids.isEmpty {
            AppLogger.player.info("Removed \(ids.count) auto-added episode(s) over limit for podcast \(showKey)")
        }
    }

    private func preferencesChanged() {
        let settings = LibraryDisplayPreferencesStore.shared.loadPreferences().podcastAutoQueueSettings
        guard settings != lastSettings else { return }
        lastSettings = settings
        Task { @MainActor [weak self] in await self?.refresh(force: true) }
    }
}
