package com.enve.app.data.podcasts

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.PodcastFeedEpisode
import com.enve.core.data.model.PodcastFeedKey
import com.enve.core.data.model.PodcastShow
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

class PodcastFeedMergeTest {
    private val feed = checkNotNull(javaClass.classLoader?.getResourceAsStream("podcasts/atp_trimmed.xml"))
        .use(PodcastFeedParser::parse)

    @Test
    fun storedEpisodeMatchedByGuidIsDropped() {
        val stored = listOf(PodcastFeedKey("svdeou1mmfjhwknm", null, "Renamed on server", null))

        assertEquals(listOf("710", "708", "706"), feedOnlyEpisodes(stored, feed).map { it.title.take(3) })
    }

    @Test
    fun fallsBackToEnclosureIgnoringScheme() {
        val stored = listOf(PodcastFeedKey(null, "https://atp.fm/audio/708/atp708.mp3", "Something else", null))

        assertEquals(listOf("710", "709", "706"), feedOnlyEpisodes(stored, feed).map { it.title.take(3) })
    }

    @Test
    fun fallsBackToNormalizedTitleWithinADay() {
        val nearby = listOf(PodcastFeedKey(null, null, "  706:  elan   VITAL ", 1787855400000L + 3_600_000L))
        val undated = listOf(PodcastFeedKey(null, null, "706: Élan Vital", null))
        val farAway = listOf(PodcastFeedKey(null, null, "706: Élan Vital", 1787855400000L + 3 * 86_400_000L))

        assertEquals(3, feedOnlyEpisodes(nearby, feed).size)
        assertEquals(3, feedOnlyEpisodes(undated, feed).size)
        assertEquals(4, feedOnlyEpisodes(farAway, feed).size)
    }

    @Test
    fun eachFeedItemIsClaimedOnceAndDuplicateGuidsCollapse() {
        val duplicated = feed + feed.first().copy(title = "Duplicate guid")
        val stored = listOf(
            PodcastFeedKey("mupxmwzqadfzlu12", null, "", null),
            PodcastFeedKey(null, "https://atp.fm/audio/mupxmwzqadfzlu12/atp710.mp3", "", null),
        )

        assertEquals(listOf("709", "708", "706"), feedOnlyEpisodes(stored, duplicated).map { it.title.take(3) })
    }

    @Test
    fun feedOnlyBookStreamsFromEnclosureUnderTheShow() {
        val show = PodcastShow(
            id = "show-1",
            title = "Accidental Tech Podcast",
            author = "ATP",
            description = null,
            coverUrl = "http://abs.test/api/items/show-1/cover",
            genres = emptyList(),
            episodes = emptyList(),
            feedUrl = "https://cdn.atp.fm/rss",
            storedFeedKeys = emptyList(),
        )
        val showBook = Book(id = "show-1", title = "ATP", connectionId = "conn", libraryId = "lib", source = BookSource.AUDIOBOOKSHELF)
        val episode: PodcastFeedEpisode = feed.first()

        val book = episode.toFeedOnlyBook(show, showBook)

        assertEquals(book.id, episode.toFeedOnlyBook(show, showBook).id)
        assertNotEquals(book.id, feed[1].toFeedOnlyBook(show, showBook).id)
        assertEquals(false, book.id.contains('#'))
        assertEquals("https://atp.fm/audio/mupxmwzqadfzlu12/atp710.mp3", book.podcastEnclosureUrl)
        assertEquals("mupxmwzqadfzlu12", book.episodeId)
        assertEquals("show-1", book.podcastLibraryItemId)
        assertEquals(AppMediaType.PODCAST, book.mediaType)
        assertEquals("conn", book.connectionId)
        assertEquals(7997L, book.duration)
        assertEquals(1790270013000L, book.addedOn)
    }
}
