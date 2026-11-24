package com.enve.app.data.podcasts

import com.enve.core.data.local.PodcastFeedProgress
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.engine.podcasts.PodcastFeedPrivacyConcern
import com.enve.engine.podcasts.PodcastFeedUrl
import com.enve.engine.podcasts.PodcastOpmlEpisode
import com.enve.engine.podcasts.PodcastOpmlError
import com.enve.engine.podcasts.PodcastOpmlException
import com.enve.engine.podcasts.PodcastOpmlLimits
import com.enve.engine.podcasts.PodcastSubscription
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class PodcastOpmlTest {
    private val overcast = """
        <?xml version="1.0" encoding="utf-8"?>
        <opml version="1.0">
          <head><title>Overcast Podcast Subscriptions</title></head>
          <body>
            <outline text="feeds">
              <outline type="rss" text="Show One" title="Show One" xmlUrl="HTTPS://Example.com:443/one.xml#x" htmlUrl="https://example.com">
                <outline type="podcast-episode" title="Episode A" pubDate="2024-03-01T10:00:00-05:00" enclosureUrl="https://cdn.example.com/a-episode.mp3" overcastId="1" progress="120" userUpdatedDate="2024-03-02T10:00:00-05:00"/>
                <outline type="podcast-episode" title="Episode B" pubDate="2024-03-08T10:00:00-05:00" enclosureUrl="https://cdn.example.com/b-episode.mp3" played="1" userUpdatedDate="2024-03-09T10:00:00-05:00"/>
                <outline type="podcast-episode" title="Untouched" enclosureUrl="https://cdn.example.com/c-episode.mp3"/>
              </outline>
              <outline type="rss" text="Gone Show" xmlUrl="itpc://gone.example.com/feed" subscribed="0">
                <outline type="podcast-episode" title="Old" played="1"/>
              </outline>
              <outline type="rss" text="Duplicate" xmlUrl="http://example.com/one.xml"/>
              <outline type="rss" text="Broken" xmlUrl="ftp://example.com/feed"/>
            </outline>
          </body>
        </opml>
    """.trimIndent().toByteArray()

    private fun parseError(bytes: ByteArray): PodcastOpmlError = try {
        PodcastOpmlParser.parse(bytes)
        fail("Expected parse failure")
        error("unreachable")
    } catch (e: PodcastOpmlException) {
        e.error
    }

    @Test
    fun parsesOvercastFeedsEpisodesAndSubscriptionState() {
        val document = PodcastOpmlParser.parse(overcast)
        assertEquals(3, document.feeds.size)
        assertEquals(1, document.invalidFeedCount)
        val one = document.feeds[0]
        assertEquals("https://example.com/one.xml", one.feedUrl)
        assertEquals(3, one.episodes.size)
        assertEquals(120L, one.episodes[0].positionSec)
        assertTrue(one.episodes[1].isPlayed)
        assertEquals("http://gone.example.com/feed", document.feeds[1].feedUrl)
        assertFalse(document.feeds[1].isSubscribed)
    }

    @Test
    fun previewMergesDuplicatesAndDeselectsUnsubscribedShows() {
        val preview = podcastImportPreview(PodcastOpmlParser.parse(overcast), listOf("https://GONE.example.com/feed"))
        assertEquals(2, preview.candidates.size)
        assertEquals(1, preview.duplicateCount)
        assertEquals(1, preview.invalidCount)
        val one = preview.candidates.first()
        assertEquals(2, one.listeningStateCount)
        assertEquals(setOf(PodcastFeedUrl.key("https://example.com/one.xml"), PodcastFeedUrl.key("http://gone.example.com/feed")), preview.defaultSelection)
        assertTrue(preview.candidates[1].isAlreadySubscribed)
    }

    @Test
    fun refusesDocumentTypesAndEntities() {
        val bomb = """<?xml version="1.0"?><!DOCTYPE opml [<!ENTITY a "aaaa">]><opml><body><outline xmlUrl="https://e.com/&a;"/></body></opml>"""
        assertEquals(PodcastOpmlError.DOCUMENT_TYPE_NOT_ALLOWED, parseError(bomb.toByteArray()))
        val external = """<?xml version="1.0"?><!doctype opml SYSTEM "file:///etc/passwd"><opml/>"""
        assertEquals(PodcastOpmlError.DOCUMENT_TYPE_NOT_ALLOWED, parseError(external.toByteArray()))
    }

    @Test
    fun rejectsUnsafeOrNonOpmlInput() {
        assertEquals(PodcastOpmlError.EMPTY, parseError(ByteArray(0)))
        assertEquals(PodcastOpmlError.UNSUPPORTED_ENCODING, parseError(byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x3C, 0x00)))
        assertEquals(PodcastOpmlError.UNSUPPORTED_ENCODING, parseError(byteArrayOf(0x3C, 0xC3.toByte(), 0x28)))
        assertEquals(PodcastOpmlError.TOO_LARGE, parseError(ByteArray(PodcastOpmlLimits.MAX_BYTES + 1) { ' '.code.toByte() }))
        assertEquals(PodcastOpmlError.NOT_OPML, parseError("<rss><channel/></rss>".toByteArray()))
        assertEquals(PodcastOpmlError.NO_FEEDS, parseError("<opml><body><outline text=\"x\"/></body></opml>".toByteArray()))
        assertEquals(PodcastOpmlError.MALFORMED, parseError("<opml><body><outline xmlUrl=\"https://e.com/f\">".toByteArray()))
        val deep = "<opml>" + "<outline>".repeat(PodcastOpmlLimits.MAX_DEPTH + 1) + "</outline>".repeat(PodcastOpmlLimits.MAX_DEPTH + 1) + "</opml>"
        assertEquals(PodcastOpmlError.TOO_COMPLEX, parseError(deep.toByteArray()))
    }

    @Test
    fun canonicalizesFeedUrls() {
        assertEquals("http://example.com/feed", PodcastFeedUrl.canonical("feed://Example.COM:80/feed#frag"))
        assertEquals("https://example.com/", PodcastFeedUrl.canonical(" https://EXAMPLE.com "))
        assertEquals("https://example.com:8443/rss?id=1", PodcastFeedUrl.canonical("https://example.com:8443/rss?id=1"))
        assertNull(PodcastFeedUrl.canonical("javascript:alert(1)"))
        assertNull(PodcastFeedUrl.canonical("file:///etc/hosts"))
        assertEquals(PodcastFeedUrl.key("http://example.com/a"), PodcastFeedUrl.key("https://example.com/a"))
    }

    @Test
    fun flagsPrivateFeeds() {
        assertEquals(PodcastFeedPrivacyConcern.CREDENTIALS, PodcastFeedUrl.privacyConcern("https://me:pw@example.com/feed"))
        assertEquals(PodcastFeedPrivacyConcern.ACCESS_KEY, PodcastFeedUrl.privacyConcern("https://example.com/feed?auth_token=abc"))
        assertEquals(PodcastFeedPrivacyConcern.PRIVATE_FEED, PodcastFeedUrl.privacyConcern("https://www.patreon.com/rss/show"))
        assertEquals(PodcastFeedPrivacyConcern.OPAQUE_TOKEN, PodcastFeedUrl.privacyConcern("https://example.com/feeds/a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8.xml"))
        assertEquals(PodcastFeedPrivacyConcern.ACCESS_KEY, PodcastFeedUrl.privacyConcern("https://example.com/feed?api%5Fkey=abc"))
        assertEquals(PodcastFeedPrivacyConcern.PRIVATE_FEED, PodcastFeedUrl.privacyConcern("https://example.com/%70rivate/show"))
        assertNull(PodcastFeedUrl.privacyConcern("https://feeds.example.com/show.xml?format=mp3"))
        assertNull(PodcastFeedUrl.privacyConcern("https://example.com/123e4567-e89b-12d3-a456-426614174000.xml"))
    }

    private fun book(id: String, title: String, enclosure: String?, guid: String? = null, durationSec: Long = 600L, addedOn: Long = 0L) = Book(
        id = id,
        title = title,
        source = BookSource.AUDIOBOOKSHELF,
        mediaType = AppMediaType.PODCAST,
        duration = durationSec,
        episodeId = guid,
        podcastEnclosureUrl = enclosure,
        addedOn = addedOn,
    )

    @Test
    fun matchesEpisodesByGuidEnclosureFileNameAndTitle() {
        val episodes = listOf(
            book("1", "First", "https://cdn.example.com/a-episode.mp3", guid = "g1"),
            book("2", "Second!", "https://tracking.example/redirect/cdn.example.com/b-episode.mp3"),
            book("3", "Third Episode", null),
        )
        val index = PodcastEpisodeIndex(episodes)
        assertEquals("1", index.match(PodcastOpmlEpisode(guid = "g1"))?.id)
        assertEquals("1", index.match(PodcastOpmlEpisode(enclosureUrl = "http://cdn.example.com/a-episode.mp3"))?.id)
        assertEquals("2", index.match(PodcastOpmlEpisode(enclosureUrl = "https://other.example/b-episode.mp3"))?.id)
        assertEquals("3", index.match(PodcastOpmlEpisode(title = "third   episode"))?.id)
        assertNull(index.match(PodcastOpmlEpisode(title = "Missing")))
    }

    @Test
    fun importedHistoryNeverOverwritesNewerOrFinishedProgress() {
        val imported = PodcastOpmlEpisode(positionSec = 300L, updatedAtMs = 2_000L)
        val newer = PodcastFeedProgress(100L, 600L, isFinished = false, updatedAtMs = 3_000L)
        assertEquals(PodcastEpisodeStateDecision.KeptExistingProgress, PodcastEpisodeStateMerge.decide(imported, newer, 600L, 10_000L))
        val finished = PodcastFeedProgress(600L, 600L, isFinished = true, updatedAtMs = 1_000L)
        assertEquals(PodcastEpisodeStateDecision.AlreadyFinished, PodcastEpisodeStateMerge.decide(imported, finished, 600L, 10_000L))
        val undated = PodcastOpmlEpisode(positionSec = 300L)
        val older = PodcastFeedProgress(100L, 600L, isFinished = false, updatedAtMs = 1_000L)
        assertEquals(PodcastEpisodeStateDecision.KeptExistingProgress, PodcastEpisodeStateMerge.decide(undated, older, 600L, 10_000L))
        val applied = PodcastEpisodeStateMerge.decide(imported, older, 600L, 10_000L) as PodcastEpisodeStateDecision.Apply
        assertEquals(PodcastFeedProgress(300L, 600L, isFinished = false, updatedAtMs = 2_000L), applied.progress)
        val played = PodcastEpisodeStateMerge.decide(PodcastOpmlEpisode(isPlayed = true), null, 0L, 10_000L) as PodcastEpisodeStateDecision.Apply
        assertTrue(played.progress.isFinished)
        assertEquals(10_000L, played.progress.updatedAtMs)
    }

    @Test
    fun applyKeepsNewestImportedStatePerEpisode() {
        val episode = book("1", "First", "https://cdn.example.com/a-episode.mp3")
        val result = applyImportedPodcastStates(
            states = listOf(
                PodcastOpmlEpisode(title = "First", positionSec = 50L, updatedAtMs = 1_000L),
                PodcastOpmlEpisode(title = "First", positionSec = 900L, updatedAtMs = 2_000L),
                PodcastOpmlEpisode(title = "Nope", isPlayed = true),
            ),
            episodes = listOf(episode),
            existing = emptyMap(),
            nowMs = 5_000L,
        )
        assertEquals(1, result.applied)
        assertEquals(1, result.unmatched)
        assertEquals(PodcastFeedProgress(600L, 600L, isFinished = false, updatedAtMs = 2_000L), result.writes[episode.uniqueKey])
    }

    @Test
    fun exportExcludesPrivateFeedsAndRoundTrips() {
        val subscriptions = listOf(
            PodcastSubscription("https://example.com/one.xml", "Show & \"One\"", null, null, 0L),
            PodcastSubscription("http://EXAMPLE.com/one.xml", "Dup", null, null, 0L),
            PodcastSubscription("https://example.com/feed?token=secret", "Private", null, null, 0L),
        )
        val played = book("1", "Done", "https://cdn.example.com/done-episode.mp3", guid = "g1", addedOn = 1_700_000_000_000L)
            .copy(isFinished = true, lastReadTime = 1_700_000_100_000L)
        val partial = book("2", "Half", "https://cdn.example.com/half-episode.mp3?key=abc").copy(currentTime = 42L)
        val plan = podcastExportPlan(subscriptions, mapOf(PodcastFeedUrl.key("https://example.com/one.xml") to listOf(played, partial)), false)
        assertEquals(1, plan.feeds.size)
        assertEquals(1, plan.duplicateCount)
        assertEquals(listOf("Private"), plan.exclusions.map { it.title })
        assertNull(plan.feeds.single().episodes[1].enclosureUrl)

        val reparsed = PodcastOpmlParser.parse(PodcastOpmlWriter.write(plan.feeds, 0L)).feeds.single()
        assertEquals("Show & \"One\"", reparsed.title)
        assertEquals(2, reparsed.episodes.size)
        assertTrue(reparsed.episodes[0].isPlayed)
        assertEquals(1_700_000_100_000L, reparsed.episodes[0].updatedAtMs)
        assertEquals(42L, reparsed.episodes[1].positionSec)
    }

    @Test
    fun escapeDropsForbiddenControlCharacters() {
        assertEquals("a&amp;b&lt;&#10;c", PodcastOpmlWriter.escapeAttribute("a&b<\n\u0001c"))
    }
}
