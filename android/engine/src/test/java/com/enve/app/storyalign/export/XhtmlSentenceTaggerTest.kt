package com.enve.app.storyalign.export

import org.jsoup.Jsoup
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class XhtmlSentenceTaggerTest {
    private val tagger = XhtmlSentenceTagger()

    @Test fun wrapsSentencesInSingleTextNode() {
        val xhtml = "<html><body><p>The quick brown fox. It jumped high.</p></body></html>"
        val r = tagger.tag(
            xhtml,
            listOf(
                XhtmlSentenceTagger.TaggedSentence("c1-sentence0", "The quick brown fox."),
                XhtmlSentenceTagger.TaggedSentence("c1-sentence1", "It jumped high."),
            ),
        )
        assertEquals(2, r.wrapped)
        assertEquals(0, r.skipped)

        val doc = Jsoup.parse(r.xhtml)
        assertNotNull(doc.getElementById("c1-sentence0"))
        assertEquals("The quick brown fox.", doc.getElementById("c1-sentence0")!!.text())
        assertEquals("It jumped high.", doc.getElementById("c1-sentence1")!!.text())

        assertTrue(doc.text().contains("The quick brown fox. It jumped high."))
    }

    @Test fun skipsSentenceStraddlingInlineElement() {
        val xhtml = "<html><body><p>Hello <em>brave</em> world today.</p></body></html>"
        val r = tagger.tag(
            xhtml,
            listOf(XhtmlSentenceTagger.TaggedSentence("c1-sentence0", "Hello brave world today.")),
        )
        assertEquals(0, r.wrapped)
        assertEquals(1, r.skipped)

        assertTrue(Jsoup.parse(r.xhtml).text().contains("Hello brave world today."))
    }

    @Test fun wrapsAcrossMultipleParagraphs() {
        val xhtml = "<html><body><p>First sentence here.</p><p>Second sentence there.</p></body></html>"
        val r = tagger.tag(
            xhtml,
            listOf(
                XhtmlSentenceTagger.TaggedSentence("c1-sentence0", "First sentence here."),
                XhtmlSentenceTagger.TaggedSentence("c1-sentence1", "Second sentence there."),
            ),
        )
        assertEquals(2, r.wrapped)
        val doc = Jsoup.parse(r.xhtml)
        assertEquals("First sentence here.", doc.getElementById("c1-sentence0")!!.text())
        assertEquals("Second sentence there.", doc.getElementById("c1-sentence1")!!.text())
    }
}
