package com.enve.hearth.podcasts

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneOffset
import java.util.Locale

class PodcastsFormatTest {

    @Test
    fun decodesNumericAndNamedEntities() {
        assertEquals("It’s here", PodcastsFormat.cleanHTML("It&#8217;s here"))
        assertEquals("Q&A — “live” …", PodcastsFormat.cleanHTML("Q&amp;A &mdash; &ldquo;live&rdquo; &hellip;"))
        assertEquals("It’s ✓ 😀", PodcastsFormat.cleanHTML("It&#x2019;s &#x2713; &#128512;"))
        assertEquals("<b> stays text", PodcastsFormat.cleanHTML("&lt;b&gt; stays text"))
    }

    @Test
    fun leavesUnknownOrInvalidEntitiesUntouched() {
        assertEquals("&bogus; &#xFFFFFFF;", PodcastsFormat.cleanHTML("&bogus; &#xFFFFFFF;"))
    }

    @Test
    fun stripsTagsAndKeepsBlockBreaks() {
        val html = "<p>I have been <em>behind</em> the sky.</p>\n<p>Weather: <a href=\"https://x\">Song</a></p>" +
            "<ul>\n<li>One</li>\n<li>Two<br/>lines</li>\n</ul>"

        assertEquals(
            "I have been behind the sky.\n\nWeather: Song\n\nOne\n\nTwo\nlines",
            PodcastsFormat.cleanHTML(html),
        )
    }

    @Test
    fun collapsesWhitespaceAndNonBreakingSpaces() {
        assertEquals("A B\n\nC", PodcastsFormat.cleanHTML("  A&nbsp;&nbsp; B \n\n\n\n C  "))
    }

    @Test
    fun sortsByDateAndSearchesTitlesAndCleanedNotes() {
        val old = episode("old", "Pilot", addedOn = 1L, description = "<p>Origins</p>")
        val new = episode("new", "Finale", addedOn = 3L, description = "It&#8217;s over")
        val mid = episode("mid", "Middle", addedOn = 2L)
        val episodes = listOf(old, new, mid)

        assertEquals(listOf("new", "mid", "old"), PodcastsFormat.sortedAndFiltered(episodes, "", newestFirst = true).map { it.id })
        assertEquals(listOf("old", "mid", "new"), PodcastsFormat.sortedAndFiltered(episodes, " ", newestFirst = false).map { it.id })
        assertEquals(listOf("new"), PodcastsFormat.sortedAndFiltered(episodes, "it’s", newestFirst = true).map { it.id })
        assertEquals(listOf("old"), PodcastsFormat.sortedAndFiltered(episodes, "PILOT", newestFirst = true).map { it.id })
        assertTrue(PodcastsFormat.sortedAndFiltered(episodes, "<p>", newestFirst = true).isEmpty())
    }

    @Test
    fun identifiesShowsSeparatelyFromEpisodes() {
        val show = Book(id = "show", title = "Radiolab", mediaType = AppMediaType.PODCAST)

        assertTrue(show.isPodcastShow)
        assertFalse(show.copy(episodeId = "ep").isPodcastShow)
        assertFalse(show.copy(mediaType = AppMediaType.AUDIOBOOK).isPodcastShow)
    }

    @Test
    fun formatsPublishedDateAsLocalizedMediumDate() {
        val aug31 = 1788134400000L

        assertEquals("Aug 31, 2026", PodcastsFormat.publishedDate(aug31, Locale.US, ZoneOffset.UTC))
        assertEquals("31 août 2026", PodcastsFormat.publishedDate(aug31, Locale.FRANCE, ZoneOffset.UTC))
        assertEquals(null, PodcastsFormat.publishedDate(0L, Locale.US, ZoneOffset.UTC))
    }

    @Test
    fun marksFeedOnlyEpisodes() {
        val stored = episode("stored", "Stored", addedOn = 1L)

        assertFalse(stored.isFeedOnlyEpisode)
        assertTrue(stored.copy(podcastEnclosureUrl = "https://example.com/ep.mp3").isFeedOnlyEpisode)
        assertFalse(stored.copy(podcastEnclosureUrl = "https://example.com/ep.mp3").isPodcastShow)
    }

    private fun episode(id: String, title: String, addedOn: Long, description: String? = null) = Book(
        id = id,
        title = title,
        description = description,
        addedOn = addedOn,
        mediaType = AppMediaType.PODCAST,
        episodeId = id,
    )
}
