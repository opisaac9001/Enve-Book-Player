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

    @Test fun wrapsInlineRangesWithoutLosingMarkupOrSentenceBoundaries() {
        val xhtml = "<html><body><p>Before. Hello <em id=\"emphasis\">brave <strong>world</strong> today. Next</em> sentence.</p></body></html>"
        val texts = listOf("Before.", "Hello brave world today.", "Next sentence.")
        val result = tagger.tag(xhtml, texts.mapIndexed { id, text ->
            XhtmlSentenceTagger.TaggedSentence("c1-sentence$id", text)
        }, allowInlineRanges = true)
        val parsed = Jsoup.parse(result.xhtml)
        assertEquals(3, result.wrapped)
        assertEquals(0, result.skipped)
        texts.forEachIndexed { id, text ->
            assertEquals(text, parsed.getElementById("c1-sentence$id")!!.text())
        }
        assertEquals("world", parsed.selectFirst("#c1-sentence1 em strong")!!.text())
        assertEquals("Next", parsed.selectFirst("#c1-sentence2 em")!!.text())
        assertEquals(1, parsed.select("#emphasis").size)
        assertEquals(Jsoup.parse(xhtml).body().wholeText(), parsed.body().wholeText())
        assertEquals(parsed.select("[id]").size, parsed.select("[id]").map { it.id() }.toSet().size)
    }

    @Test fun fullSourceTaggingDistinguishesAnEarlierUnalignedRepeatedSentence() {
        val result = tagger.tag("<html><body><p>Yes. Between. Yes.</p></body></html>", listOf(
            XhtmlSentenceTagger.TaggedSentence("c1-sentence0", "Yes."),
            XhtmlSentenceTagger.TaggedSentence("c1-sentence1", "Between."),
            XhtmlSentenceTagger.TaggedSentence("c1-sentence2", "Yes."),
        ), allowInlineRanges = true)
        val body = Jsoup.parse(result.xhtml).body()
        assertEquals(listOf("c1-sentence0", "c1-sentence1", "c1-sentence2"), body.select("span[id]").map { it.id() })
        assertEquals("Yes.", body.getElementById("c1-sentence2")!!.text())
    }
}
