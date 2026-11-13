import Foundation
import Testing

@testable import enve

struct PodcastMigrationOPMLTests {
    @Test func plainOPMLReadsNestedCategoriesAndAliasedSchemes() throws {
        let document = try PodcastOPMLParser.parse(Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <opml version="2.0">
              <head><title>Subscriptions</title></head>
              <body>
                <outline text="Science">
                  <outline type="rss" text="Orbit &amp; Beyond" xmlUrl="https://Example.COM:443/orbit.xml#top"/>
                </outline>
                <outline text="No title" xmlUrl="feed://podcasts.example.org/news"/>
                <outline text="Broken" xmlUrl="mailto:someone@example.com"/>
              </body>
            </opml>
            """.utf8))

        #expect(document.feeds.map(\.title) == ["Orbit & Beyond", "No title"])
        #expect(document.feeds.map(\.feedURL) == ["https://example.com/orbit.xml", "http://podcasts.example.org/news"])
        #expect(document.feeds.allSatisfy { $0.isSubscribed && $0.episodes.isEmpty })
        #expect(document.invalidFeedCount == 1)
    }

    @Test func overcastExtendedExportCarriesEpisodeState() throws {
        let document = try PodcastOPMLParser.parse(Data("""
            <?xml version="1.0" encoding="utf-8"?>
            <opml version="1.0">
              <head><title>Overcast Podcast Subscriptions</title></head>
              <body>
                <outline text="playlists">
                  <outline type="podcast-playlist" title="All Episodes"/>
                </outline>
                <outline text="feeds">
                  <outline type="rss" overcastId="1" text="Show" title="Show" xmlUrl="https://example.com/show.rss" subscribed="1">
                    <outline type="podcast-episode" overcastId="10" pubDate="2024-03-01T08:00:00-05:00" title="Finished" enclosureUrl="https://cdn.example.com/finished.mp3" userUpdatedDate="2024-03-02T09:30:00-05:00" played="1"/>
                    <outline type="podcast-episode" overcastId="11" pubDate="2024-03-08T08:00:00-05:00" title="Halfway" enclosureUrl="https://cdn.example.com/halfway.mp3" userUpdatedDate="2024-03-09T09:30:00-05:00" progress="1234"/>
                    <outline type="podcast-episode" overcastId="12" title="Deleted" enclosureUrl="https://cdn.example.com/deleted.mp3" userDeleted="1"/>
                  </outline>
                  <outline type="rss" text="Old show" xmlUrl="https://example.com/old.rss" subscribed="0"/>
                </outline>
              </body>
            </opml>
            """.utf8))

        let show = try #require(document.feeds.first)
        #expect(document.feeds.count == 2)
        #expect(document.feeds[1].isSubscribed == false)
        #expect(show.episodes.count == 3)
        #expect(show.episodes[0].isPlayed)
        #expect(show.episodes[0].updatedAt == ISO8601DateFormatter().date(from: "2024-03-02T14:30:00Z"))
        #expect(show.episodes[1].position == 1234)
        #expect(!show.episodes[1].isPlayed)
        #expect(!show.episodes[2].hasListeningState)
    }

    @Test func malformedAndUnsafeFilesFailClearly() {
        #expect(throws: PodcastOPMLError.empty) { try PodcastOPMLParser.parse(Data()) }
        let malformed = #expect(throws: PodcastOPMLError.self) {
            try PodcastOPMLParser.parse(Data("<opml>\n<body>\n<outline xmlUrl=\"https://a.example/f\">\n</opml>".utf8))
        }
        if case .malformed(let line) = malformed {
            #expect(line >= 3)
        } else {
            Issue.record("Expected a malformed-file error, got \(String(describing: malformed))")
        }
        #expect(throws: PodcastOPMLError.documentTypeNotAllowed) {
            try PodcastOPMLParser.parse(Data("""
                <?xml version="1.0"?>
                <!DOCTYPE opml [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;&lol;">]>
                <opml><body><outline xmlUrl="https://a.example/&lol2;"/></body></opml>
                """.utf8))
        }
        #expect(throws: PodcastOPMLError.notOPML) {
            try PodcastOPMLParser.parse(Data("<rss><channel><title>Not OPML</title></channel></rss>".utf8))
        }
        #expect(throws: PodcastOPMLError.noFeeds) {
            try PodcastOPMLParser.parse(Data("<opml><body><outline text=\"Empty folder\"/></body></opml>".utf8))
        }
        #expect(throws: PodcastOPMLError.unsupportedEncoding) {
            try PodcastOPMLParser.parse(Data([0xFF, 0xFE, 0x3C, 0x00]))
        }
        #expect(throws: PodcastOPMLError.tooLarge) {
            try PodcastOPMLParser.parse(Data(count: PodcastOPMLParser.maximumBytes + 1))
        }
    }

    @Test func deeplyNestedFilesAreRejected() {
        let depth = PodcastOPMLParser.maximumDepth + 2
        let xml = "<opml><body>" + String(repeating: "<outline text=\"x\">", count: depth)
            + "<outline xmlUrl=\"https://a.example/f\"/>" + String(repeating: "</outline>", count: depth) + "</body></opml>"
        #expect(throws: PodcastOPMLError.tooComplex) { try PodcastOPMLParser.parse(Data(xml.utf8)) }
    }

    @Test func writerEscapesAttributesAndRoundTrips() throws {
        let updated = Date(timeIntervalSince1970: 1_700_000_000)
        let feeds = [
            PodcastOPMLExportFeed(
                title: "Q&A <Live> \"Quotes\" 'Single'\u{0001}",
                feedURL: "https://example.com/feed?format=rss&page=1",
                episodes: [
                    PodcastOPMLEpisode(
                        title: "Line\nbreak & more",
                        guid: "guid-<1>",
                        enclosureURL: "https://cdn.example.com/a.mp3?x=1&y=2",
                        publishedAt: updated,
                        updatedAt: updated,
                        position: 61.9
                    ),
                    PodcastOPMLEpisode(title: "Done", guid: "guid-2", updatedAt: updated, isPlayed: true),
                ]
            ),
            PodcastOPMLExportFeed(title: "Plain", feedURL: "https://example.org/plain.xml", episodes: []),
        ]
        let data = PodcastOPMLWriter.data(feeds: feeds, createdAt: updated)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text.contains("Q&amp;A &lt;Live&gt; &quot;Quotes&quot; &apos;Single&apos;\""))
        #expect(!text.contains("\u{0001}"))
        #expect(text.contains("Line&#10;break &amp; more"))
        #expect(text.contains("progress=\"61\""))

        let parsed = try PodcastOPMLParser.parse(data)
        #expect(parsed.feeds.map(\.title) == ["Q&A <Live> \"Quotes\" 'Single'", "Plain"])
        #expect(parsed.feeds[0].feedURL == "https://example.com/feed?format=rss&page=1")
        #expect(parsed.feeds[0].episodes[0].guid == "guid-<1>")
        #expect(parsed.feeds[0].episodes[0].title == "Line\nbreak & more")
        #expect(parsed.feeds[0].episodes[0].enclosureURL == "https://cdn.example.com/a.mp3?x=1&y=2")
        #expect(parsed.feeds[0].episodes[0].position == 61)
        #expect(parsed.feeds[0].episodes[0].updatedAt == updated)
        #expect(parsed.feeds[0].episodes[1].isPlayed)
    }

    @Test func feedKeysDedupSpellingsOfTheSameFeed() {
        let key = PodcastFeedURL.key("https://Example.com/Feed.xml")
        #expect(PodcastFeedURL.key("http://example.com/Feed.xml") == key)
        #expect(PodcastFeedURL.key("  https://example.com:443/Feed.xml#latest ") == key)
        #expect(PodcastFeedURL.key("feed://example.com/Feed.xml") == key)
        #expect(PodcastFeedURL.key("feed:https://example.com/Feed.xml") == key)
        #expect(PodcastFeedURL.key("https://example.com/feed.xml") != key)
        #expect(PodcastFeedURL.key("https://example.com/Feed.xml?page=2") != key)
    }

    @Test func privacyClassifierIsConservativeButNotParanoid() {
        #expect(PodcastFeedURL.privacyConcern("https://feeds.example.com/show.xml?format=mp3&id=1234") == nil)
        #expect(PodcastFeedURL.privacyConcern("https://feeds.acast.com/public/shows/5e7b777ba085cbe7192b0607") == nil)
        #expect(PodcastFeedURL.privacyConcern("https://www.omnycontent.com/d/playlist/1d1f0a4c-8b39-4f3b-9d0b-ab1e00f3c5d8/podcast.rss") == nil)

        #expect(PodcastFeedURL.privacyConcern("https://user:secret@example.com/feed.xml") == .credentials)
        #expect(PodcastFeedURL.privacyConcern("https://example.com/feed.xml?auth=abc") == .accessKey)
        #expect(PodcastFeedURL.privacyConcern("https://example.com/feed.xml?access_token=abc") == .accessKey)
        #expect(PodcastFeedURL.privacyConcern("https://example.com/feed.xml?k=Ab12Cd34Ef56Gh78Ij90Kl12Mn34Op56Qr") == .accessKey)
        #expect(PodcastFeedURL.privacyConcern("https://www.patreon.com/rss/creator") == .privateFeed)
        #expect(PodcastFeedURL.privacyConcern("https://api.substack.com/feed/podcast/1/private/abc.rss") == .privateFeed)
        #expect(PodcastFeedURL.privacyConcern("https://feeds.example.fm/content/Ab12Cd34Ef56Gh78Ij90Kl12Mn34Op56Qr.rss") == .opaqueToken)
    }
}
