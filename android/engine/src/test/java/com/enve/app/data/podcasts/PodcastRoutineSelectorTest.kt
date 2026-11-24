package com.enve.app.data.podcasts

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.engine.podcasts.PodcastFeedUrl
import com.enve.engine.podcasts.PodcastRoutine
import com.enve.engine.podcasts.PodcastRoutineLimits
import com.enve.engine.podcasts.PodcastRoutinePick
import com.enve.engine.podcasts.PodcastRoutineRule
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PodcastRoutineSelectorTest {
    private val feedUrl = "https://example.com/feed.xml"
    private val otherFeedUrl = "https://example.com/other.xml"

    private fun episode(id: String, addedOn: Long, finished: Boolean = false, positionSec: Long = 0L) = Book(
        id = id,
        title = "Episode $id",
        source = BookSource.LOCAL,
        mediaType = AppMediaType.PODCAST,
        addedOn = addedOn,
        currentTime = positionSec,
        isFinished = finished,
    )

    private fun rule(pick: PodcastRoutinePick, url: String = feedUrl, id: String = "rule") =
        PodcastRoutineRule(id, url, "Show", pick)

    private fun resolve(
        rules: List<PodcastRoutineRule>,
        feeds: Map<String, PodcastRoutineFeed>,
        offline: Boolean = false,
        downloaded: Set<String> = emptySet(),
    ) = PodcastRoutineSelector.resolve(
        rules,
        feeds.mapKeys { PodcastFeedUrl.key(it.key) },
        setOf(PodcastFeedUrl.key(feedUrl), PodcastFeedUrl.key(otherFeedUrl)),
        offline,
    ) { it.id in downloaded }

    @Test
    fun newestUnplayedSkipsFinishedEpisodes() {
        val feed = PodcastRoutineFeed.Fresh(listOf(episode("3", 300, finished = true), episode("2", 200), episode("1", 100)))
        val outcome = resolve(listOf(rule(PodcastRoutinePick.NewestUnplayed)), mapOf(feedUrl to feed)).single()
        assertEquals(listOf("2"), outcome.episodes.map(Book::id))
        assertNull(outcome.note)
    }

    @Test
    fun nextUnplayedContinuesAfterLastFinishedEpisode() {
        val feed = PodcastRoutineFeed.Fresh(
            listOf(episode("4", 400), episode("3", 300), episode("2", 200, finished = true), episode("1", 100)),
        )
        val outcome = resolve(listOf(rule(PodcastRoutinePick.NextUnplayed(2))), mapOf(feedUrl to feed)).single()
        assertEquals(listOf("3", "4"), outcome.episodes.map(Book::id))
    }

    @Test
    fun nextUnplayedResumesStartedEpisode() {
        val feed = PodcastRoutineFeed.Fresh(listOf(episode("3", 300), episode("2", 200, positionSec = 60), episode("1", 100)))
        val outcome = resolve(listOf(rule(PodcastRoutinePick.NextUnplayed(1))), mapOf(feedUrl to feed)).single()
        assertEquals(listOf("2"), outcome.episodes.map(Book::id))
    }

    @Test
    fun laterRulesDoNotRequeueEarlierPicks() {
        val feed = PodcastRoutineFeed.Fresh(listOf(episode("1", 100)))
        val outcomes = resolve(
            listOf(rule(PodcastRoutinePick.NewestUnplayed, id = "a"), rule(PodcastRoutinePick.NewestUnplayed, id = "b")),
            mapOf(feedUrl to feed),
        )
        assertEquals(listOf("1"), outcomes[0].episodes.map(Book::id))
        assertTrue(outcomes[1].episodes.isEmpty())
        assertEquals("Already queued by an earlier rule.", outcomes[1].note)
    }

    @Test
    fun offlineNextUnplayedHoldsBackWhenNextIsNotDownloaded() {
        val feed = PodcastRoutineFeed.Stale(listOf(episode("3", 300), episode("2", 200), episode("1", 100)))
        val outcome = resolve(
            listOf(rule(PodcastRoutinePick.NextUnplayed(3))),
            mapOf(feedUrl to feed),
            offline = true,
            downloaded = setOf("1", "3"),
        ).single()
        assertEquals(listOf("1"), outcome.episodes.map(Book::id))
        assertEquals("Stopped before “Episode 2”, which isn't downloaded.", outcome.note)
    }

    @Test
    fun staleListingOnlineAddsNote() {
        val feed = PodcastRoutineFeed.Stale(listOf(episode("1", 100)))
        val outcome = resolve(listOf(rule(PodcastRoutinePick.NewestUnplayed)), mapOf(feedUrl to feed)).single()
        assertEquals(listOf("1"), outcome.episodes.map(Book::id))
        assertNotNull(outcome.note)
    }

    @Test
    fun unsubscribedAndFailedFeedsExplainThemselves() {
        val outcomes = PodcastRoutineSelector.resolve(
            listOf(rule(PodcastRoutinePick.NewestUnplayed, url = "https://gone.example/feed", id = "gone"), rule(PodcastRoutinePick.NewestUnplayed)),
            mapOf(PodcastFeedUrl.key(feedUrl) to PodcastRoutineFeed.Failed),
            setOf(PodcastFeedUrl.key(feedUrl)),
            isOffline = false,
        ) { false }
        assertEquals("You're no longer subscribed to this show.", outcomes[0].note)
        assertEquals("The feed couldn't be loaded. Try again later.", outcomes[1].note)
    }

    @Test
    fun ruleFeedUrlsMatchAcrossSchemeAndHostSpelling() {
        val feed = PodcastRoutineFeed.Fresh(listOf(episode("1", 100)))
        val outcome = resolve(
            listOf(rule(PodcastRoutinePick.NewestUnplayed, url = "feed://EXAMPLE.com:80/feed.xml#top")),
            mapOf(feedUrl to feed),
        ).single()
        assertEquals(listOf("1"), outcome.episodes.map(Book::id))
    }

    @Test
    fun downloadedOnlyFeedServesNewestButRefusesSerialOrder() {
        val feed = PodcastRoutineFeed.DownloadedOnly(listOf(episode("2", 200), episode("1", 100)))
        val outcomes = resolve(
            listOf(rule(PodcastRoutinePick.NewestUnplayed, id = "a"), rule(PodcastRoutinePick.NextUnplayed(1), id = "b")),
            mapOf(feedUrl to feed),
            offline = true,
            downloaded = setOf("1", "2"),
        )
        assertEquals(listOf("2"), outcomes[0].episodes.map(Book::id))
        assertTrue(outcomes[1].episodes.isEmpty())
        assertNotNull(outcomes[1].note)
    }

    @Test
    fun chronologicalKeepsFeedOrderForUndatedEpisodes() {
        val ordered = PodcastRoutineSelector.chronological(listOf(episode("b", 0), episode("a", 0), episode("c", 50), episode("a", 0)))
        assertEquals(listOf("a", "b", "c"), ordered.map(Book::id))
    }

    @Test
    fun sanitizedClampsCountsNamesAndRules() {
        val rules = List(PodcastRoutineLimits.MAX_RULES + 5) { rule(PodcastRoutinePick.NextUnplayed(99), id = "r$it") }
        val routine = PodcastRoutineStore.sanitized(PodcastRoutine("id", "   ", rules))
        assertEquals(PodcastRoutineLimits.DEFAULT_NAME, routine.name)
        assertEquals(PodcastRoutineLimits.MAX_RULES, routine.rules.size)
        assertEquals(PodcastRoutinePick.NextUnplayed(PodcastRoutineLimits.episodeCounts.last), routine.rules.first().pick)
    }

    @Test
    fun routinesRoundTripThroughJson() {
        val routine = PodcastRoutine(
            "id",
            "Morning walk",
            listOf(rule(PodcastRoutinePick.NewestUnplayed, id = "a"), rule(PodcastRoutinePick.NextUnplayed(3), url = otherFeedUrl, id = "b")),
        )
        assertEquals(listOf(routine), Json.decodeFromString<List<PodcastRoutine>>(Json.encodeToString(listOf(routine))))
    }
}
