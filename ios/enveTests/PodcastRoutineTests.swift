import Foundation
import Testing

@testable import enve

@MainActor
struct PodcastRoutineTests {
    private static let showA = "https://a.example/feed"
    private static let showB = "https://b.example/feed"

    @Test func newestUnplayedSkipsFinishedAndKeepsABegunEpisode() {
        let episodes = [
            episode("a1", day: 1),
            episode("a2", day: 2, position: 400),
            episode("a3", day: 3, position: 1000),
        ]
        let outcomes = resolve([rule(Self.showA, .newestUnplayed)], feeds: [Self.showA: .fresh(episodes)])
        #expect(outcomes[0].episodes.map(\.episodeId) == ["a2"])
        #expect(outcomes[0].episodes[0].currentTime == 400)
        #expect(outcomes[0].note == nil)
    }

    @Test func nextUnplayedContinuesInOrderAfterTheLastPlayedEpisode() {
        let episodes = [
            episode("a5", day: 5),
            episode("a1", day: 1),
            episode("a2", day: 2, position: 1000),
            episode("a3", day: 3, position: 250),
            episode("a4", day: 4),
            episode("a6", day: 6),
        ]
        let outcomes = resolve([rule(Self.showA, .nextUnplayed(3))], feeds: [Self.showA: .fresh(episodes)])
        #expect(outcomes[0].episodes.map(\.episodeId) == ["a3", "a4", "a5"])

        let fresh = [episode("b2", day: 2), episode("b1", day: 1), episode("b3", day: 3)]
        let firstListen = resolve([rule(Self.showB, .nextUnplayed(2))], feeds: [Self.showB: .fresh(fresh)])
        #expect(firstListen[0].episodes.map(\.episodeId) == ["b1", "b2"])
    }

    @Test func offlineUsesOnlyDownloadsAndNeverSkipsAheadInASeries() {
        let episodes = [episode("a1", day: 1, position: 1000), episode("a2", day: 2), episode("a3", day: 3), episode("a4", day: 4)]
        let downloaded: Set<String?> = ["a3", "a4"]
        let outcomes = PodcastRoutineSelector.resolve(
            rules: [rule(Self.showA, .nextUnplayed(2)), rule(Self.showA, .newestUnplayed)],
            feeds: [PodcastFeedURL.key(Self.showA): .stale(episodes)],
            subscribedKeys: [PodcastFeedURL.key(Self.showA)],
            isOffline: true,
            isDownloaded: { downloaded.contains($0.episodeId) }
        )
        #expect(outcomes[0].episodes.isEmpty)
        #expect(outcomes[0].note?.contains("“a2” is next but isn't downloaded") == true)
        #expect(outcomes[1].episodes.map(\.episodeId) == ["a4"])

        let partial = PodcastRoutineSelector.resolve(
            rules: [rule(Self.showA, .nextUnplayed(3))],
            feeds: [PodcastFeedURL.key(Self.showA): .stale(episodes)],
            subscribedKeys: [PodcastFeedURL.key(Self.showA)],
            isOffline: true,
            isDownloaded: { $0.episodeId == "a2" || $0.episodeId == "a4" }
        )
        #expect(partial[0].episodes.map(\.episodeId) == ["a2"])
        #expect(partial[0].note == "Stopped before “a3”, which isn't downloaded.")
    }

    @Test func offlineWithoutAnEpisodeListRefusesSerialRules() {
        let downloads = [episode("a3", day: 3), episode("a5", day: 5)]
        let outcomes = PodcastRoutineSelector.resolve(
            rules: [rule(Self.showA, .nextUnplayed(1)), rule(Self.showA, .newestUnplayed)],
            feeds: [PodcastFeedURL.key(Self.showA): .downloadedOnly(downloads)],
            subscribedKeys: [PodcastFeedURL.key(Self.showA)],
            isOffline: true,
            isDownloaded: { _ in true }
        )
        #expect(outcomes[0].episodes.isEmpty)
        #expect(outcomes[0].note?.contains("isn't available offline") == true)
        #expect(outcomes[1].episodes.map(\.episodeId) == ["a5"])
    }

    @Test func rulesDeduplicateAcrossTheRoutineAndExplainEmptyResults() {
        let episodes = [episode("a1", day: 1), episode("a2", day: 2), episode("a3", day: 3)]
        let finished = [episode("b1", day: 1, position: 1000)]
        let outcomes = PodcastRoutineSelector.resolve(
            rules: [
                rule(Self.showA, .newestUnplayed),
                rule(Self.showA, .nextUnplayed(3)),
                rule(Self.showA, .newestUnplayed),
                rule(Self.showB, .newestUnplayed),
                rule("https://gone.example/feed", .newestUnplayed),
                rule("https://down.example/feed", .newestUnplayed),
            ],
            feeds: [
                PodcastFeedURL.key(Self.showA): .fresh(episodes),
                PodcastFeedURL.key(Self.showB): .fresh(finished),
                PodcastFeedURL.key("https://down.example/feed"): .failed,
            ],
            subscribedKeys: Set([Self.showA, Self.showB, "https://down.example/feed"].map(PodcastFeedURL.key)),
            isOffline: false,
            isDownloaded: { _ in false }
        )
        #expect(outcomes[0].episodes.map(\.episodeId) == ["a3"])
        #expect(outcomes[1].episodes.map(\.episodeId) == ["a1", "a2"])
        #expect(outcomes[2].episodes.isEmpty)
        #expect(outcomes[2].note == "Already queued by an earlier rule.")
        #expect(outcomes[3].note == "Every episode has been played.")
        #expect(outcomes[4].note == "You're no longer subscribed to this show.")
        #expect(outcomes[5].note == "The feed couldn't be loaded. Try again later.")
        #expect(outcomes.flatMap(\.episodes).count == Set(outcomes.flatMap(\.episodes).map(\.stableId)).count)
    }

    @Test func staleListsAreUsedButFlaggedWhenOnline() {
        let outcomes = resolve([rule(Self.showA, .newestUnplayed)], feeds: [Self.showA: .stale([episode("a1", day: 1)])])
        #expect(outcomes[0].episodes.map(\.episodeId) == ["a1"])
        #expect(outcomes[0].note?.hasPrefix("Couldn't refresh this show") == true)
    }

    @Test func storePersistsEditsPerProfileAndSanitizes() throws {
        let owner = Suite()
        let child = Suite()
        defer {
            owner.remove()
            child.remove()
        }
        let store = PodcastRoutineStore(defaults: owner.defaults)
        let morning = try #require(store.create(named: "  Morning walk  ", rules: [rule(Self.showA, .nextUnplayed(40))]))
        let evening = try #require(store.create(named: "   "))
        #expect(morning.name == "Morning walk")
        #expect(morning.rules[0].pick == .nextUnplayed(PodcastRoutineRule.Pick.countRange.upperBound))
        #expect(evening.name == PodcastRoutineStore.defaultName)

        var edited = morning
        edited.rules.append(rule(Self.showB, .newestUnplayed))
        edited.rules.swapAt(0, 1)
        store.save(edited)
        store.move(id: evening.id, by: -1)
        store.delete(id: UUID())

        let reloaded = PodcastRoutineStore(defaults: owner.defaults)
        #expect(reloaded.routines.map(\.name) == [PodcastRoutineStore.defaultName, "Morning walk"])
        #expect(reloaded.routine(id: morning.id)?.rules.map(\.feedURL) == [Self.showB, Self.showA])
        #expect(PodcastRoutineStore(defaults: child.defaults).routines.isEmpty)

        reloaded.delete(id: morning.id)
        #expect(PodcastRoutineStore(defaults: owner.defaults).routines.map(\.id) == [evening.id])
    }

    @Test func runnerPlaysTheResolvedQueueOnce() async throws {
        var played: [(ids: [String?], group: String)] = []
        var fetched: [String] = []
        let routine = PodcastRoutine(name: "Drive", rules: [rule(Self.showA, .newestUnplayed), rule(Self.showB, .nextUnplayed(2))])
        let runner = makeRunner(
            online: true,
            load: { url in
                fetched.append(url)
                return url == Self.showA ? [episode("a1", day: 1)] : [episode("b1", day: 1), episode("b2", day: 2), episode("b3", day: 3)]
            },
            play: { books, group in
                played.append((books.map(\.episodeId), group))
                return true
            }
        )
        let run = try #require(await runner.resolveAndPlay(routine))
        #expect(run.didPlay)
        #expect(run.queuedCount == 3)
        #expect(fetched == [Self.showA, Self.showB])
        #expect(played.count == 1)
        #expect(played.first?.ids == ["a1", "b1", "b2"])
        #expect(played.first?.group == "podcast-routine:\(routine.id.uuidString)")
    }

    @Test func runnerLeavesTheQueueAloneWhenNothingResolves() async throws {
        var playCalls = 0
        let routine = PodcastRoutine(name: "Empty", rules: [rule(Self.showA, .newestUnplayed)])
        let runner = makeRunner(
            online: true,
            load: { _ in throw URLError(.timedOut) },
            play: { _, _ in
                playCalls += 1
                return true
            }
        )
        let run = try #require(await runner.resolveAndPlay(routine))
        #expect(!run.didPlay)
        #expect(playCalls == 0)
        #expect(run.explanations.first?.note == "The feed couldn't be loaded. Try again later.")
    }

    @Test func runnerOfflineMakesNoNetworkRequests() async throws {
        var fetched = 0
        var played: [[String?]] = []
        let routine = PodcastRoutine(name: "Offline", rules: [rule(Self.showA, .newestUnplayed)])
        let runner = makeRunner(
            online: false,
            load: { _ in
                fetched += 1
                return []
            },
            downloads: [episode("a2", day: 2, feedURL: Self.showA), episode("x", day: 9, feedURL: "https://other.example/feed")],
            play: { books, _ in
                played.append(books.map(\.episodeId))
                return true
            }
        )
        let run = try #require(await runner.resolveAndPlay(routine))
        #expect(fetched == 0)
        #expect(run.wasOffline)
        #expect(played == [["a2"]])
    }

    @Test func runnerStopsWhenTheProfileIsNoLongerActive() async {
        var active = true
        var playCalls = 0
        let routine = PodcastRoutine(name: "Switch", rules: [rule(Self.showA, .newestUnplayed)])
        let runner = makeRunner(
            online: true,
            load: { _ in
                active = false
                return [episode("a1", day: 1)]
            },
            isActive: { active },
            play: { _, _ in
                playCalls += 1
                return true
            }
        )
        #expect(await runner.resolveAndPlay(routine) == nil)
        #expect(playCalls == 0)
    }

    private func rule(_ feedURL: String, _ pick: PodcastRoutineRule.Pick) -> PodcastRoutineRule {
        PodcastRoutineRule(feedURL: feedURL, showTitle: feedURL, pick: pick)
    }

    private func episode(_ guid: String, day: Int, position: TimeInterval = 0, feedURL: String = PodcastRoutineTests.showA) -> Book {
        PodcastFixtures.episode(guid, title: guid, day: day, position: position, feedURL: feedURL)
    }

    private func resolve(_ rules: [PodcastRoutineRule], feeds: [String: PodcastRoutineFeedEpisodes]) -> [PodcastRoutineRuleOutcome] {
        PodcastRoutineSelector.resolve(
            rules: rules,
            feeds: Dictionary(uniqueKeysWithValues: feeds.map { (PodcastFeedURL.key($0.key), $0.value) }),
            subscribedKeys: Set(feeds.keys.map(PodcastFeedURL.key)),
            isOffline: false,
            isDownloaded: { _ in false }
        )
    }

    private func makeRunner(
        online: Bool,
        load: @escaping (String) async throws -> [Book],
        downloads: [Book] = [],
        isActive: @escaping () -> Bool = { true },
        play: @escaping ([Book], String) -> Bool
    ) -> PodcastRoutineRunner {
        let subscriptions = [Self.showA, Self.showB].map {
            PodcastSubscription(id: $0, title: $0, feedURL: $0, dateSubscribed: Date(timeIntervalSince1970: 0))
        }
        return PodcastRoutineRunner(
            subscriptions: { subscriptions },
            loadEpisodes: load,
            cachedEpisodes: { _ in nil },
            downloadedEpisodes: { downloads },
            isOnline: { online },
            isDownloaded: { book in downloads.contains { $0.stableId == book.stableId } },
            isActive: isActive,
            play: play
        )
    }

    private struct Suite {
        let name = "PodcastRoutineTests.\(UUID().uuidString)"
        var defaults: UserDefaults { UserDefaults(suiteName: name)! }

        func remove() {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
    }
}
