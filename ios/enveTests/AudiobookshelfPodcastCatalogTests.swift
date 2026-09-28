import Foundation
import Testing

@testable import enve

@MainActor
struct AudiobookshelfPodcastCatalogTests {
    @Test func audiobookshelfPodcastsAreIncludedByDefault() throws {
        #expect(UserPreferences.default.includeAudiobookshelfPodcasts)

        let decoded = try JSONDecoder().decode(UserPreferences.self, from: Data("{}".utf8))
        #expect(decoded.includeAudiobookshelfPodcasts)

        let disabled = try JSONDecoder().decode(
            UserPreferences.self,
            from: Data(#"{"includeAudiobookshelfPodcasts":false}"#.utf8)
        )
        #expect(!disabled.includeAudiobookshelfPodcasts)
    }

    @Test func itemMediaTypePodcastClassifiesWithoutLibraryType() {
        for itemMediaType in ["podcast", "podcasts", "Podcast"] {
            let mediaType = ABSMediaTypeClassifier.classify(
                libraryMediaType: nil,
                itemMediaType: itemMediaType,
                hasAudio: true,
                ebookFormat: nil,
                hasEbookFile: false
            )
            #expect(mediaType == .podcast)
        }
    }

    @Test func libraryListItemExposesFeedAndStoredCountWithoutEpisodes() throws {
        let item = try AudiobookshelfProvider.decodePodcastItem(Fixture.libraryListItem(numEpisodes: 1))

        #expect(item.id == "li_show")
        #expect(item.title == "Signals")
        #expect(item.author == "Ada Host")
        #expect(item.genres == ["Technology"])
        #expect(item.hasCover)
        #expect(item.addedAt == Date(timeIntervalSince1970: 1_704_067_200))
        #expect(item.feedURL == "https://feeds.example.test/signals.xml")
        #expect(item.storedEpisodeCount == 1)
        #expect(item.storedEpisodes == nil)
    }

    @Test func itemDetailExposesOnlyStoredEpisodes() throws {
        let item = try AudiobookshelfProvider.decodePodcastItem(Fixture.itemDetail)
        let stored = try #require(item.storedEpisodes)

        #expect(item.storedEpisodeCount == nil)
        #expect(stored.map(\.id) == ["ep_stored", "ep_legacy", "ep_local"])
        #expect(stored[0].guid == "guid-12")
        #expect(stored[0].enclosureURL == "https://cdn.example.test/signals/12.mp3")
        #expect(stored[0].audioFileIno == "9001")
        #expect(stored[0].duration == 1800.5)
        #expect(stored[0].publishedAt == Date(timeIntervalSince1970: 1_704_103_200))
        #expect(stored[1].guid == nil)
        #expect(stored[1].enclosureURL == "https://cdn.example.test/signals/11.mp3")
        #expect(stored[2].guid == nil)
        #expect(stored[2].enclosureURL == nil)
        #expect(stored[2].title == "Weekly Recap")
    }

    @Test func feedCatalogAddsOnlyEpisodesTheServerDoesNotStore() throws {
        let item = try AudiobookshelfProvider.decodePodcastItem(Fixture.itemDetail)
        let stored = try #require(item.storedEpisodes)
        let feed = try RSSPodcastParser.shared.parseFeed(from: Fixture.feed)
        #expect(feed.episodes.count == 7)

        let feedOnly = ABSPodcastEpisodeMerge.feedOnlyEpisodes(stored: stored, feed: feed.episodes)

        // Matching uses GUID, enclosure, or title plus nearby date without collapsing title-only duplicates.
        #expect(feedOnly.map(\.id) == ["guid-14", "https://cdn.example.test/signals/15.mp3", "guid-recap-2"])
    }

    @Test func feedOnlyMergeIsDeterministicWithoutStoredEpisodes() throws {
        let feed = try RSSPodcastParser.shared.parseFeed(from: Fixture.feed)

        let first = ABSPodcastEpisodeMerge.feedOnlyEpisodes(stored: [], feed: feed.episodes)
        let second = ABSPodcastEpisodeMerge.feedOnlyEpisodes(stored: [], feed: feed.episodes)

        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.count == 6)
        #expect(Set(first.map(\.id)).count == 6)
    }

    @Test func showKeepsStoredIdentityAndPlaysFeedEpisodesDirectly() throws {
        let connection = ServerConnection(
            name: "Fixture",
            url: "https://abs.example.test",
            type: .audiobookshelf,
            token: "fixture-token"
        )
        let provider = AudiobookshelfProvider(connection: connection)
        let item = try AudiobookshelfProvider.decodePodcastItem(Fixture.itemDetail)
        let feed = try RSSPodcastParser.shared.parseFeed(from: Fixture.feed)
        let progress = [
            "li_show/ep_stored": UserMediaProgress(
                id: "progress-1",
                libraryItemId: "li_show",
                providerId: connection.id,
                episodeId: "ep_stored",
                currentTime: 600,
                progress: 0.33,
                isFinished: false,
                duration: 1800.5,
                lastUpdate: Date(timeIntervalSince1970: 1_705_000_000),
                ebookProgress: nil
            )
        ]

        func makeShow() -> AudiobookshelfProvider.PodcastShow {
            provider.podcastShow(
                from: item,
                storedEpisodes: item.storedEpisodes ?? [],
                feedEpisodes: feed.episodes,
                libraryId: "lib_podcasts",
                baseURL: URL(string: connection.url)!,
                token: "fixture-token",
                progress: progress
            )
        }

        let show = makeShow()
        #expect(show.id == "li_show")
        #expect(show.feedURL == nil)
        #expect(show.episodes.count == 6)
        #expect(Set(show.episodes.map(\.id)).count == 6)
        #expect(show.episodes.allSatisfy { $0.isPodcastEpisode && $0.podcastLibraryItemId == "li_show" })

        let stored = try #require(show.episodes.first { $0.id == "li_show_ep_stored" })
        #expect(stored.source == .audiobookshelf)
        #expect(stored.providerId == connection.id)
        #expect(stored.partKey == "li_show")
        #expect(stored.episodeId == "ep_stored")
        #expect(stored.audioFileIno == "9001")
        #expect(stored.currentTime == 600)
        #expect(stored.lastUpdate == Date(timeIntervalSince1970: 1_705_000_000))
        #expect(stored.addedAt == Date(timeIntervalSince1970: 1_704_103_200))

        let feedOnly = try #require(show.episodes.first { $0.id == "li_show_rss_guid-14" })
        #expect(feedOnly.source == .local)
        #expect(feedOnly.providerId != connection.id)
        #expect(feedOnly.partKey == "https://cdn.example.test/signals/14.mp3")
        #expect(feedOnly.episodeId == "guid-14")
        #expect(feedOnly.podcastName == "Signals")
        #expect(feedOnly.duration == 1500)
        #expect(feedOnly.addedAt == Date(timeIntervalSince1970: 1_705_312_800))
        #expect(feedOnly.currentTime == 0)

        let refreshed = makeShow()
        #expect(refreshed.episodes.map(\.stableId) == show.episodes.map(\.stableId))
        #expect(refreshed.episodes.map(\.uniqueId) == show.episodes.map(\.uniqueId))
    }

    @Test func showWithoutStoredEpisodesStillListsTheWholeFeed() throws {
        let connection = ServerConnection(
            name: "Fixture",
            url: "https://abs.example.test",
            type: .audiobookshelf,
            token: "fixture-token"
        )
        let provider = AudiobookshelfProvider(connection: connection)
        let item = try AudiobookshelfProvider.decodePodcastItem(Fixture.libraryListItem(numEpisodes: 0))
        let feed = try RSSPodcastParser.shared.parseFeed(from: Fixture.feed)
        #expect(item.storedEpisodeCount == 0)

        let show = provider.podcastShow(
            from: item,
            storedEpisodes: [],
            feedEpisodes: feed.episodes,
            libraryId: "lib_podcasts",
            baseURL: URL(string: connection.url)!,
            token: "fixture-token",
            progress: [:]
        )

        #expect(show.episodes.count == 6)
        #expect(show.episodes.allSatisfy { $0.source == .local && $0.providerId != connection.id })
        #expect(show.episodes.allSatisfy { $0.partKey?.contains("://cdn.example.test/signals/") == true })
    }
}

private enum Fixture {
    static func libraryListItem(numEpisodes: Int) -> Data {
        Data(
            """
            {
              "id": "li_show",
              "ino": "123456",
              "libraryId": "lib_podcasts",
              "folderId": "folder_1",
              "path": "/podcasts/Signals",
              "relPath": "Signals",
              "isFile": false,
              "mtimeMs": 1704067200000,
              "ctimeMs": 1704067200000,
              "birthtimeMs": 1704067200000,
              "addedAt": 1704067200000,
              "updatedAt": 1704067200000,
              "isMissing": false,
              "isInvalid": false,
              "mediaType": "podcast",
              "media": {
                "id": "pod_show",
                "metadata": {
                  "title": "Signals",
                  "titleIgnorePrefix": "Signals",
                  "author": "Ada Host",
                  "description": "Weekly conversations about sound.",
                  "releaseDate": "2023-12-01",
                  "genres": ["Technology"],
                  "feedUrl": "https://feeds.example.test/signals.xml",
                  "imageUrl": "https://feeds.example.test/signals.jpg",
                  "itunesPageUrl": null,
                  "itunesId": null,
                  "itunesArtistId": null,
                  "explicit": false,
                  "language": "en",
                  "type": "episodic"
                },
                "coverPath": "/metadata/items/li_show/cover.jpg",
                "tags": [],
                "numEpisodes": \(numEpisodes),
                "autoDownloadEpisodes": false,
                "autoDownloadSchedule": "0 * * * *",
                "lastEpisodeCheck": 1704067200000,
                "maxEpisodesToKeep": 0,
                "maxNewEpisodesToDownload": 3,
                "size": 28311552
              },
              "numFiles": 1,
              "size": 28311552
            }
            """.utf8
        )
    }

    static let itemDetail = Data(
        """
        {
          "id": "li_show",
          "ino": "123456",
          "libraryId": "lib_podcasts",
          "folderId": "folder_1",
          "path": "/podcasts/Signals",
          "relPath": "Signals",
          "isFile": false,
          "mtimeMs": 1704067200000,
          "ctimeMs": 1704067200000,
          "birthtimeMs": 1704067200000,
          "addedAt": 1704067200000,
          "updatedAt": 1704067200000,
          "lastScan": 1704067200000,
          "scanVersion": "2.19.0",
          "isMissing": false,
          "isInvalid": false,
          "mediaType": "podcast",
          "media": {
            "id": "pod_show",
            "libraryItemId": "li_show",
            "metadata": {
              "title": "Signals",
              "author": "Ada Host",
              "description": "Weekly conversations about sound.",
              "releaseDate": "2023-12-01",
              "genres": ["Technology"],
              "feedUrl": "https://feeds.example.test/signals.xml",
              "imageUrl": "https://feeds.example.test/signals.jpg",
              "itunesPageUrl": null,
              "itunesId": null,
              "itunesArtistId": null,
              "explicit": false,
              "language": "en",
              "type": "episodic"
            },
            "coverPath": "/metadata/items/li_show/cover.jpg",
            "tags": [],
            "episodes": [
              {
                "libraryItemId": "li_show",
                "podcastId": "pod_show",
                "id": "ep_stored",
                "oldEpisodeId": null,
                "index": 1,
                "season": "",
                "episode": "12",
                "episodeType": "full",
                "title": "Episode 12",
                "subtitle": "",
                "description": "<p>Twelve.</p>",
                "enclosure": {
                  "url": "https://cdn.example.test/signals/12.mp3",
                  "type": "audio/mpeg",
                  "length": "28311552"
                },
                "guid": "guid-12",
                "pubDate": "Mon, 01 Jan 2024 10:00:00 +0000",
                "chapters": [],
                "audioFile": {
                  "index": 1,
                  "ino": "9001",
                  "metadata": {
                    "filename": "12.mp3",
                    "ext": ".mp3",
                    "path": "/podcasts/Signals/12.mp3",
                    "relPath": "12.mp3",
                    "size": 28311552,
                    "mtimeMs": 1704200000000,
                    "ctimeMs": 1704200000000,
                    "birthtimeMs": 1704200000000
                  },
                  "addedAt": 1704200000000,
                  "updatedAt": 1704200000000,
                  "trackNumFromMeta": null,
                  "discNumFromMeta": null,
                  "trackNumFromFilename": null,
                  "discNumFromFilename": null,
                  "manuallyVerified": false,
                  "exclude": false,
                  "error": null,
                  "format": "MP2/3 (MPEG audio layer 2/3)",
                  "duration": 1800.5,
                  "bitRate": 128000,
                  "language": null,
                  "codec": "mp3",
                  "timeBase": "1/14112000",
                  "channels": 2,
                  "channelLayout": "stereo",
                  "chapters": [],
                  "embeddedCoverArt": null,
                  "metaTags": {},
                  "mimeType": "audio/mpeg"
                },
                "publishedAt": 1704103200000,
                "addedAt": 1704200000000,
                "updatedAt": 1704200000000,
                "duration": 1800.5,
                "size": 28311552
              },
              {
                "libraryItemId": "li_show",
                "podcastId": "pod_show",
                "id": "ep_legacy",
                "oldEpisodeId": "ep_legacy_old",
                "index": 2,
                "season": "",
                "episode": "11",
                "episodeType": "full",
                "title": "Episode 11",
                "subtitle": "",
                "description": "<p>Eleven.</p>",
                "enclosure": {
                  "url": "https://cdn.example.test/signals/11.mp3",
                  "type": "audio/mpeg",
                  "length": "26000000"
                },
                "guid": null,
                "pubDate": "Mon, 25 Dec 2023 10:00:00 +0000",
                "chapters": [],
                "audioFile": {
                  "index": 2,
                  "ino": "9002",
                  "metadata": {
                    "filename": "11.mp3",
                    "ext": ".mp3",
                    "path": "/podcasts/Signals/11.mp3",
                    "relPath": "11.mp3",
                    "size": 26000000,
                    "mtimeMs": 1703500000000,
                    "ctimeMs": 1703500000000,
                    "birthtimeMs": 1703500000000
                  },
                  "addedAt": 1703500000000,
                  "updatedAt": 1703500000000,
                  "duration": 1700,
                  "mimeType": "audio/mpeg"
                },
                "publishedAt": 1703498400000,
                "addedAt": 1703500000000,
                "updatedAt": 1703500000000,
                "duration": 1700,
                "size": 26000000
              },
              {
                "libraryItemId": "li_show",
                "podcastId": "pod_show",
                "id": "ep_local",
                "oldEpisodeId": null,
                "index": 3,
                "season": "",
                "episode": "",
                "episodeType": "full",
                "title": "Weekly Recap",
                "subtitle": "",
                "description": null,
                "enclosure": null,
                "guid": null,
                "pubDate": null,
                "chapters": [],
                "audioFile": {
                  "index": 3,
                  "ino": "9003",
                  "metadata": {
                    "filename": "recap.mp3",
                    "ext": ".mp3",
                    "path": "/podcasts/Signals/recap.mp3",
                    "relPath": "recap.mp3",
                    "size": 9000000,
                    "mtimeMs": 1704706200000,
                    "ctimeMs": 1704706200000,
                    "birthtimeMs": 1704706200000
                  },
                  "addedAt": 1704706200000,
                  "updatedAt": 1704706200000,
                  "duration": 600,
                  "mimeType": "audio/mpeg"
                },
                "publishedAt": 1704706200000,
                "addedAt": 1704706200000,
                "updatedAt": 1704706200000,
                "duration": 600,
                "size": 9000000
              }
            ],
            "autoDownloadEpisodes": false,
            "autoDownloadSchedule": "0 * * * *",
            "lastEpisodeCheck": 1704067200000,
            "maxEpisodesToKeep": 0,
            "maxNewEpisodesToDownload": 3,
            "size": 63311552
          },
          "libraryFiles": [],
          "size": 63311552
        }
        """.utf8
    )

    static let feed = Data(
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
          <channel>
            <title>Signals</title>
            <itunes:author>Ada Host</itunes:author>
            <description>Weekly conversations about sound.</description>
            <itunes:image href="https://feeds.example.test/signals.jpg"/>
            <item>
              <title>Episode 12</title>
              <guid isPermaLink="false">guid-12</guid>
              <pubDate>Mon, 01 Jan 2024 10:00:00 +0000</pubDate>
              <enclosure url="https://cdn.example.test/signals/12-remastered.mp3" type="audio/mpeg" length="28311552"/>
              <itunes:duration>30:00</itunes:duration>
            </item>
            <item>
              <title>Episode 11</title>
              <guid>guid-11-new</guid>
              <pubDate>Mon, 25 Dec 2023 10:00:00 +0000</pubDate>
              <enclosure url="http://cdn.example.test/signals/11.mp3" type="audio/mpeg" length="26000000"/>
            </item>
            <item>
              <title>Weekly  Recap</title>
              <guid>guid-recap-1</guid>
              <pubDate>Mon, 08 Jan 2024 11:00:00 +0000</pubDate>
              <enclosure url="https://cdn.example.test/signals/recap-1.mp3" type="audio/mpeg" length="9000000"/>
            </item>
            <item>
              <title>Episode 14</title>
              <guid>guid-14</guid>
              <pubDate>Mon, 15 Jan 2024 10:00:00 +0000</pubDate>
              <enclosure url="https://cdn.example.test/signals/14.mp3" type="audio/mpeg" length="24000000"/>
              <itunes:duration>25:00</itunes:duration>
              <description>Fourteen.</description>
            </item>
            <item>
              <title>Episode 15</title>
              <pubDate>Tue, 16 Jan 2024 10:00:00 +0000</pubDate>
              <enclosure url="https://cdn.example.test/signals/15.mp3" type="audio/mpeg" length="25000000"/>
            </item>
            <item>
              <title>Weekly Recap</title>
              <guid>guid-recap-2</guid>
              <pubDate>Mon, 15 Jan 2024 09:30:00 +0000</pubDate>
              <enclosure url="https://cdn.example.test/signals/recap-2.mp3" type="audio/mpeg" length="9000000"/>
            </item>
            <item>
              <title>Episode 14 (repeat)</title>
              <guid>guid-14</guid>
              <pubDate>Mon, 15 Jan 2024 10:00:00 +0000</pubDate>
              <enclosure url="https://cdn.example.test/signals/14-repeat.mp3" type="audio/mpeg" length="24000000"/>
            </item>
          </channel>
        </rss>
        """.utf8
    )
}
