package com.enve.app.data.podcasts

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PodcastFeedParserTest {
    private fun parseFixture() = checkNotNull(javaClass.classLoader?.getResourceAsStream("podcasts/atp_trimmed.xml"))
        .use(PodcastFeedParser::parse)

    @Test
    fun parsesPlayableItemsInFeedOrder() {
        val episodes = parseFixture()

        assertEquals(
            listOf("710: That New Mouse Pad Feeling", "709: Steel-Cable Insurance", "708: Duo & Done", "706: Élan Vital"),
            episodes.map { it.title },
        )
        val newest = episodes.first()
        assertEquals("mupxmwzqadfzlu12", newest.guid)
        assertEquals(1790270013000L, newest.publishedAtMs)
        assertEquals(7997L, newest.durationSec)
        assertEquals("https://atp.fm/audio/mupxmwzqadfzlu12/atp710.mp3", newest.enclosureUrl)
        assertEquals("audio/mpeg", newest.enclosureType)
        assertEquals("<ul><li>It&#8217;s <a href=\"https://stjude.org/atp\">St. Jude</a> time!</li></ul>", newest.description)
    }

    @Test
    fun fallsBackForGuidDescriptionAndDates() {
        val (_, stored, noGuid, iso) = parseFixture()

        assertEquals(7662L, stored.durationSec)
        assertEquals(1789680369000L, stored.publishedAtMs)
        assertEquals("http://atp.fm/audio/708/atp708.mp3", noGuid.guid)
        assertEquals("<p>Encoded notes only.</p>", noGuid.description)
        assertEquals(1788987600000L, noGuid.publishedAtMs)
        assertEquals(3723L, noGuid.durationSec)
        assertEquals("Summary fallback.", iso.description)
        assertEquals(1787855400000L, iso.publishedAtMs)
        assertEquals(2730L, iso.durationSec)
        assertEquals("audio/mpeg", iso.enclosureType)
    }

    @Test
    fun parsesDurationsAndRejectsGarbage() {
        assertEquals(90L, PodcastFeedParser.parseDuration("90"))
        assertEquals(90L, PodcastFeedParser.parseDuration("90.7"))
        assertEquals(754L, PodcastFeedParser.parseDuration("12:34"))
        assertEquals(0L, PodcastFeedParser.parseDuration("about an hour"))
        assertEquals(0L, PodcastFeedParser.parseDuration("1:2:3:4"))
        assertNull(PodcastFeedParser.parseDate("yesterday"))
        assertEquals(1788465600000L, PodcastFeedParser.parseDate("Thu, 03 Sep 2026 20:00:00 GMT"))
    }

    @Test
    fun ignoresExternalEntities() {
        val xml = """<?xml version="1.0"?>
            <!DOCTYPE rss [<!ENTITY xxe SYSTEM "file:///etc/passwd">]>
            <rss><channel><item><title>Leak &xxe;</title><enclosure url="https://x.test/a.mp3"/></item></channel></rss>
        """.trimIndent()

        val episode = PodcastFeedParser.parse(xml.byteInputStream()).single()

        assertEquals("Leak", episode.title)
    }
}
