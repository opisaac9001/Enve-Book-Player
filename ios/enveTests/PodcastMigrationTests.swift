import Foundation
import Testing

@testable import enve

@MainActor
struct PodcastMigrationTests {
    private static let feedURL = "https://example.com/show.xml"

    @Test func previewMergesDuplicatesAndRecognisesExistingSubscriptions() {
        let document = PodcastOPMLDocument(
            feeds: [
                PodcastOPMLFeed(title: "Show", feedURL: "https://example.com/show.xml", episodes: [played("a")]),
                PodcastOPMLFeed(title: "Show again", feedURL: "http://EXAMPLE.com/show.xml", episodes: [inProgress("b", at: 30)]),
                PodcastOPMLFeed(title: "Known", feedURL: "https://known.example/feed"),
                PodcastOPMLFeed(title: "Dropped", feedURL: "https://old.example/feed", isSubscribed: false),
            ],
            invalidFeedCount: 2
        )
        let preview = PodcastImportPreview(document: document, existingFeedURLs: ["http://known.example/feed"])

        #expect(preview.candidates.map(\.title) == ["Show", "Known", "Dropped"])
        #expect(preview.duplicateCount == 1)
        #expect(preview.invalidCount == 2)
        #expect(preview.newCount == 2)
        #expect(preview.alreadySubscribedCount == 1)
        #expect(preview.candidates[0].playedCount == 1)
        #expect(preview.candidates[0].inProgressCount == 1)
        #expect(preview.listeningStateCount == 2)
        #expect(preview.defaultSelection == [PodcastFeedURL.key("https://example.com/show.xml"), PodcastFeedURL.key("https://known.example/feed")])
    }

    @Test func mergeNeverRewindsNewerProgressOrUnfinishesEpisodes() {
        let now = Date(timeIntervalSince1970: 10_000)
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 5_000)

        let finished: PodcastEpisodeProgress.Stored = (progress: 995, duration: 1000, lastUpdated: 100)
        #expect(PodcastEpisodeStateMerge.decide(imported: inProgress("x", at: 10, updatedAt: newer), existing: finished, episodeDuration: 1000, now: now) == .alreadyFinished)

        let recent: PodcastEpisodeProgress.Stored = (progress: 600, duration: 1000, lastUpdated: 3_000)
        #expect(PodcastEpisodeStateMerge.decide(imported: inProgress("x", at: 100, updatedAt: older), existing: recent, episodeDuration: 1000, now: now) == .keptExistingProgress)
        #expect(PodcastEpisodeStateMerge.decide(imported: played("x", updatedAt: older), existing: recent, episodeDuration: 1000, now: now) == .keptExistingProgress)
        #expect(PodcastEpisodeStateMerge.decide(imported: inProgress("x", at: 100), existing: recent, episodeDuration: 1000, now: now) == .keptExistingProgress)

        #expect(PodcastEpisodeStateMerge.decide(imported: played("x", updatedAt: newer), existing: recent, episodeDuration: 1000, now: now)
            == .apply(position: 1000, duration: 1000, updatedAt: newer))
        #expect(PodcastEpisodeStateMerge.decide(imported: inProgress("x", at: 5_000, updatedAt: newer), existing: nil, episodeDuration: 1000, now: now)
            == .apply(position: 1000, duration: 1000, updatedAt: newer))
        #expect(PodcastEpisodeStateMerge.decide(imported: inProgress("x", at: 42), existing: nil, episodeDuration: nil, now: now)
            == .apply(position: 42, duration: 0, updatedAt: now))
        #expect(PodcastEpisodeStateMerge.decide(imported: played("x"), existing: nil, episodeDuration: nil, now: now) == .missingDuration)
    }

    @Test func episodeIndexMatchesWithoutGUIDs() {
        let episodes = [
            PodcastFixtures.episode("guid-1", title: "Pilot", day: 1, enclosure: "https://traffic.example.fm/AAA111pilot.mp3"),
            PodcastFixtures.episode("guid-2", title: "Second Episode!", day: 8, enclosure: "https://cdn.example.com/two.mp3?ref=feed"),
            PodcastFixtures.episode("guid-3", title: "Bonus", day: 15, enclosure: "https://cdn.example.com/bonus-file-3.mp3"),
            PodcastFixtures.episode("guid-4", title: "Bonus", day: 40, enclosure: "https://cdn.example.com/bonus-file-4.mp3"),
        ]
        let index = PodcastEpisodeIndex(episodes: episodes)

        #expect(index.match(PodcastOPMLEpisode(guid: "guid-3"))?.episodeId == "guid-3")
        #expect(index.match(PodcastOPMLEpisode(enclosureURL: "http://cdn.example.com/two.mp3?ref=feed"))?.episodeId == "guid-2")
        #expect(index.match(PodcastOPMLEpisode(enclosureURL: "https://dts.tracker.example/redirect.mp3/traffic.example.fm/AAA111pilot.mp3"))?.episodeId == "guid-1")
        #expect(index.match(PodcastOPMLEpisode(title: "second episode"))?.episodeId == "guid-2")
        #expect(index.match(PodcastOPMLEpisode(title: "Bonus")) == nil)
        #expect(index.match(PodcastOPMLEpisode(title: "Bonus", publishedAt: PodcastFixtures.date(day: 40).addingTimeInterval(3_600)))?.episodeId == "guid-4")
        #expect(index.match(PodcastOPMLEpisode(title: "Gone")) == nil)
    }

    @Test func importAppliesHistoryOnceAndReimportIsIdempotent() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let updated = Date(timeIntervalSince1970: 50_000)
        let feedEpisodes = [
            PodcastFixtures.episode("guid-1", title: "One", day: 1, duration: 1000),
            PodcastFixtures.episode("guid-2", title: "Two", day: 2, duration: 1000),
            PodcastFixtures.episode("guid-3", title: "Three", day: 3, duration: nil),
        ]
        let service = fixture.service(episodes: [Self.feedURL: feedEpisodes])
        fixture.progress.saveProgress(for: feedEpisodes[1], progress: 700, duration: 1000, at: Date(timeIntervalSince1970: 90_000))

        let preview = PodcastImportPreview(
            document: PodcastOPMLDocument(
                feeds: [
                    PodcastOPMLFeed(title: "Show", feedURL: Self.feedURL, episodes: [
                        played("guid-1", updatedAt: updated),
                        inProgress("guid-2", at: 100, updatedAt: updated),
                        played("guid-3", updatedAt: updated),
                        played("missing", updatedAt: updated),
                    ]),
                    PodcastOPMLFeed(title: "Unreachable", feedURL: "https://down.example/feed", episodes: [played("z", updatedAt: updated)]),
                    PodcastOPMLFeed(title: "Plain", feedURL: "https://plain.example/feed"),
                ],
                invalidFeedCount: 0
            ),
            existingFeedURLs: []
        )

        let first = await service.importFeeds(from: preview, selection: preview.defaultSelection)
        #expect(first.subscribed == 3)
        #expect(first.applied == 1)
        #expect(first.keptExisting == 1)
        #expect(first.missingDuration == 1)
        #expect(first.unmatched == 1)
        #expect(first.unloadedFeeds == ["Unreachable"])
        #expect(first.unloadedStates == 1)
        #expect(fixture.subscriptions.feeds.count == 3)
        let finished = try #require(fixture.progress.loadProgress(for: feedEpisodes[0]))
        #expect(finished.progress == 1000)
        #expect(finished.lastUpdated == updated.timeIntervalSince1970)
        #expect(fixture.progress.loadProgress(for: feedEpisodes[1])?.progress == 700)

        let again = await service.importFeeds(from: preview, selection: preview.defaultSelection)
        #expect(again.subscribed == 0)
        #expect(again.alreadySubscribed == 3)
        #expect(again.applied == 0)
        #expect(again.alreadyFinished == 1)
        #expect(fixture.subscriptions.feeds.count == 3)
        #expect(fixture.progress.loadProgress(for: feedEpisodes[0])?.progress == 1000)
    }

    @Test func importOnlyTouchesSelectedFeedsAndStopsForInactiveProfiles() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let preview = PodcastImportPreview(
            document: PodcastOPMLDocument(
                feeds: [
                    PodcastOPMLFeed(title: "Keep", feedURL: "https://keep.example/feed"),
                    PodcastOPMLFeed(title: "Skip", feedURL: "https://skip.example/feed"),
                ],
                invalidFeedCount: 0
            ),
            existingFeedURLs: []
        )
        let service = fixture.service(episodes: [:])
        let report = await service.importFeeds(from: preview, selection: [PodcastFeedURL.key("https://keep.example/feed")])
        #expect(report.subscribed == 1)
        #expect(fixture.subscriptions.feeds.map(\.title) == ["Keep"])

        let inactive = fixture.service(episodes: [:], isActive: false)
        let blocked = await inactive.importFeeds(from: preview, selection: preview.defaultSelection)
        #expect(blocked.wasInterrupted)
        #expect(fixture.subscriptions.feeds.map(\.title) == ["Keep"])
    }

    @Test func exportOmitsPrivateFeedsByDefaultAndExplainsWhy() {
        let subscriptions = [
            subscription("Public", "https://example.com/public.xml?format=rss"),
            subscription("Public again", "http://EXAMPLE.com/public.xml?format=rss"),
            subscription("Supporters", "https://www.patreon.com/rss/creator?auth=abc123"),
            subscription("Token", "https://example.com/feed.xml?token=abc"),
        ]
        let started = PodcastFixtures.episode("guid-1", title: "Started", day: 1, position: 300)
        let done = PodcastFixtures.episode("guid-2", title: "Done", day: 2, position: 1000)
        let untouched = PodcastFixtures.episode("guid-3", title: "New", day: 3)
        let privateEnclosure = PodcastFixtures.episode("guid-4", title: "Signed", day: 4, position: 10, enclosure: "https://cdn.example.com/a.mp3?signature=xyz")
        let episodes = [PodcastFeedURL.key("https://example.com/public.xml?format=rss"): [started, done, untouched, privateEnclosure]]

        let plan = PodcastExportPlan(subscriptions: subscriptions, episodesByFeedKey: episodes, includePrivateFeeds: false)
        #expect(plan.feeds.map(\.title) == ["Public"])
        #expect(plan.duplicateCount == 1)
        #expect(plan.exclusions.map(\.title) == ["Supporters", "Token"])
        #expect(plan.exclusions.map(\.concern) == [.accessKey, .accessKey])
        #expect(plan.feeds[0].episodes.map(\.guid) == ["guid-1", "guid-2", "guid-4"])
        #expect(plan.feeds[0].episodes[0].position == 300)
        #expect(plan.feeds[0].episodes[1].isPlayed)
        #expect(plan.feeds[0].episodes[2].enclosureURL == nil)

        let data = PodcastOPMLWriter.data(feeds: plan.feeds, createdAt: Date())
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("patreon"))
        #expect(!text.contains("token="))
        #expect(!text.contains("signature="))

        let everything = PodcastExportPlan(subscriptions: subscriptions, episodesByFeedKey: [:], includePrivateFeeds: true)
        #expect(everything.feeds.count == 3)
        #expect(everything.exclusions.isEmpty)
    }

    @Test func hydrationRestoresStoredPositionAndCompletion() {
        let base = PodcastFixtures.episode("guid-1", title: "One", day: 1, duration: nil)
        let hydrated = PodcastEpisodeProgress.hydrate(base, stored: (progress: 1_195, duration: 1_200, lastUpdated: 77))
        #expect(hydrated.currentTime == 1_195)
        #expect(hydrated.duration == 1_200)
        #expect(hydrated.isFinished)
        #expect(hydrated.lastUpdate == Date(timeIntervalSince1970: 77))
        #expect(PodcastEpisodeProgress.hydrate(base, stored: nil) == base)
    }

    @Test func reportSummaryIsHonestAboutWhatWasSkipped() {
        var report = PodcastImportReport()
        report.subscribed = 1
        report.missingDuration = 2
        report.unmatched = 1
        report.unloadedFeeds = ["Down"]
        report.unloadedStates = 4
        report.wasInterrupted = true
        let lines = report.summaryLines
        #expect(lines.first == "Added 1 show.")
        #expect(lines.contains { $0.hasPrefix("2 played episodes couldn't be marked finished") })
        #expect(lines.contains { $0.hasPrefix("1 episode no longer in the show's feed") })
        #expect(lines.contains { $0.contains("4 episodes") && $0.contains("Down") })
        #expect(lines.last?.contains("import the same file again") == true)
    }

    private func played(_ guid: String, updatedAt: Date? = nil) -> PodcastOPMLEpisode {
        PodcastOPMLEpisode(title: guid, guid: guid, updatedAt: updatedAt, isPlayed: true)
    }

    private func inProgress(_ guid: String, at position: TimeInterval, updatedAt: Date? = nil) -> PodcastOPMLEpisode {
        PodcastOPMLEpisode(title: guid, guid: guid, updatedAt: updatedAt, position: position)
    }

    private func subscription(_ title: String, _ feedURL: String) -> PodcastSubscription {
        PodcastSubscription(id: feedURL, title: title, feedURL: feedURL, dateSubscribed: Date(timeIntervalSince1970: 0))
    }

    private struct Fixture {
        let suiteName = "PodcastMigrationTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let subscriptions: PodcastSubscriptionStore
        let progress: BookProgressStore

        @MainActor
        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            subscriptions = PodcastSubscriptionStore(defaults: defaults)
            progress = BookProgressStore(defaults: defaults)
        }

        @MainActor
        func service(episodes: [String: [Book]], isActive: Bool = true) -> PodcastMigrationService {
            let subscriptions = subscriptions
            return PodcastMigrationService(
                subscriptions: { subscriptions.feeds },
                subscribe: { subscriptions.subscribe(contentsOf: $0) },
                progress: progress,
                cachedEpisodes: { _ in nil },
                loadEpisodes: { url in
                    guard let list = episodes[url] else { throw URLError(.cannotConnectToHost) }
                    return list
                },
                isActive: { isActive },
                now: { Date(timeIntervalSince1970: 60_000) }
            )
        }

        func remove() {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

enum PodcastFixtures {
    static func date(day: Int) -> Date {
        Date(timeIntervalSince1970: Double(day) * 86_400)
    }

    static func episode(
        _ guid: String,
        title: String,
        day: Int,
        duration: TimeInterval? = 1000,
        position: TimeInterval = 0,
        feedURL: String = "https://example.com/show.xml",
        enclosure: String? = nil
    ) -> Book {
        Book(
            id: "rss_\(guid)",
            title: title,
            partKey: enclosure ?? "https://cdn.example.com/\(guid)-episode-audio.mp3",
            duration: duration,
            isPodcastEpisode: true,
            episodeId: guid,
            podcastLibraryItemId: feedURL,
            podcastName: "Show",
            addedAt: date(day: day),
            currentTime: position,
            isFinished: duration.map { position >= $0 } ?? false
        )
    }
}
