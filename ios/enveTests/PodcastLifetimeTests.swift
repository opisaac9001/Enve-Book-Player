import Foundation
import Testing

@testable import enve

@MainActor
struct PodcastLifetimeTests {
    @Test func retainedToolsStopAfterTheirEngineIsReleased() async {
        let suite = "PodcastLifetimeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let subscriptions = PodcastSubscriptionStore(defaults: defaults)
        var engine: PodcastsEngine? = PodcastsEngine(
            subscriptionStore: subscriptions,
            routineStore: PodcastRoutineStore(defaults: defaults),
            episodeProgress: BookProgressStore(defaults: defaults)
        )
        weak let released = engine
        let migration = engine!.migration
        let runner = engine!.routineRunner
        engine = nil
        #expect(released == nil)

        let preview = PodcastImportPreview(
            document: PodcastOPMLDocument(feeds: [PodcastOPMLFeed(title: "Show", feedURL: "https://example.com/feed")], invalidFeedCount: 0),
            existingFeedURLs: []
        )
        let report = await migration.importFeeds(from: preview, selection: preview.defaultSelection)
        #expect(report.wasInterrupted)
        #expect(subscriptions.feeds.isEmpty)
        #expect(await migration.prepareExport(includePrivateFeeds: false, includeProgress: false) == nil)
        #expect(await runner.resolveAndPlay(PodcastRoutine(name: "Retired")) == nil)
    }

    @Test func exportOmitsCredentialsWhenAnEpisodeGUIDIsAlsoAnAudioURL() {
        let feed = "https://example.com/show.xml"
        let signedAudio = "https://example.com/audio.mp3?token=private-access"
        let episode = PodcastFixtures.episode(signedAudio, title: "Episode", day: 1, position: 50, enclosure: signedAudio)
        let subscription = PodcastSubscription(id: feed, title: "Show", feedURL: feed, dateSubscribed: Date())
        let plan = PodcastExportPlan(
            subscriptions: [subscription],
            episodesByFeedKey: [PodcastFeedURL.key(feed): [episode]],
            includePrivateFeeds: false
        )
        let xml = String(decoding: PodcastOPMLWriter.data(feeds: plan.feeds, createdAt: Date()), as: UTF8.self)
        #expect(!xml.contains("private-access"))
        #expect(plan.episodeStateCount == 1)
        #expect(plan.feeds.first?.episodes.first?.title == "Episode")
    }
}
