package com.enve.app.storyalign.epub

import com.enve.engine.storyalign.StoryAlignGranularity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EpubXhtmlSentenceTest {

    private fun sentences(xhtml: String) =
        EpubXhtmlTextParser.getXHtmlSentences(xhtml, StoryAlignGranularity.SENTENCE)

    @Test fun singleParagraphTwoSentences() {
        val out = sentences("<html><body><p>One two three. Four five six.</p></body></html>")
        assertEquals(2, out.size)
        assertTrue(out[0].contains("One two three"))
        assertTrue(out.none { it.contains("BLOCK_BOUNDARY") })
    }

    @Test fun paragraphsAreSeparateBlocks() {
        val out = sentences("<html><body><p>First one here.</p><p>Second one here.</p></body></html>")
        assertEquals(2, out.size)
        assertTrue(out.any { it.contains("First one here") })
        assertTrue(out.any { it.contains("Second one here") })
    }

    @Test fun inlineElementsDoNotSplitSentences() {
        val out = sentences("<html><body><p>Hello <em>brave</em> world today.</p></body></html>")
        assertEquals(1, out.size)
        assertTrue(out[0].contains("Hello brave world today"))
    }

    @Test fun nestedBlocksFlatten() {
        val out = sentences("<html><body><div><p>Alpha beta.</p><p>Gamma delta.</p></div></body></html>")
        assertTrue(out.size >= 2)
        assertTrue(out.any { it.contains("Alpha beta") })
        assertTrue(out.any { it.contains("Gamma delta") })
        assertTrue(out.none { it.contains("BLOCK_BOUNDARY") })
    }

    @Test fun parseText_blockSeparatedAndResources() {
        val (text, hasScript, resources) = EpubXhtmlTextParser.parseText(
            "<html><head><link href=\"style.css\"/></head><body><p>A sentence.</p><p>B sentence.</p></body></html>",
        )
        assertTrue(text.contains("A sentence."))
        assertTrue(text.contains("B sentence."))
        assertTrue(!hasScript)
        assertTrue(resources.contains("style.css"))
    }

    @Test fun parseText_detectsScript() {
        val (_, hasScript, resources) = EpubXhtmlTextParser.parseText(
            "<html><body><script src=\"app.js\"></script><p>Hi there.</p></body></html>",
        )
        assertTrue(hasScript)
        assertTrue(resources.contains("app.js"))
    }
}
