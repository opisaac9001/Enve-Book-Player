package com.enve.app.ui.screens.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderFootnoteContentTest {
    @Test
    fun pandocEndnoteShowsWithoutItsBacklink() {
        val html = """
            <html><body><p>Text<a href="#fn1" role="doc-noteref"><sup>1</sup></a></p>
            <section role="doc-endnotes"><ol><li id="fn1"><p>The note text.<a href="#fnref1" role="doc-backlink">↩︎</a></p></li></ol></section>
            </body></html>
        """.trimIndent()

        val note = epubNoteHtml(html, "fn1", linkedAsNoteRef = false)

        assertNotNull(note)
        assertTrue(note!!.contains("The note text."))
        assertFalse(note.contains("↩"))
    }

    @Test
    fun epubTwoAsideTargetIsANote() {
        val html = """<html><body><aside id="n2" epub:type="footnote"><p>Aside note.</p></aside></body></html>"""

        assertEquals("<p>Aside note.</p>", epubNoteHtml(html, "n2", linkedAsNoteRef = false))
    }

    @Test
    fun calibreFootnoteClassOnTheBlockIsANote() {
        val html = """<html><body><p class="calibre_footnote"><a id="fn3" href="ch1.html#r3">3</a> Calibre note.</p></body></html>"""

        val note = epubNoteHtml(html, "fn3", linkedAsNoteRef = false)

        assertNotNull(note)
        assertTrue(note!!.contains("Calibre note."))
    }

    @Test
    fun plainChapterTargetNavigates() {
        val html = """<html><body><div id="ch2"><h1 id="title">Chapter 2</h1><p>Body text.</p></div></body></html>"""

        assertNull(epubNoteHtml(html, "ch2", linkedAsNoteRef = false))
        assertNull(epubNoteHtml(html, "title", linkedAsNoteRef = true))
    }

    @Test
    fun backlinkFromNotesToChapterTextNavigates() {
        val html = """<html><body><p>Long paragraph with a reference<a id="ref1" href="notes.html#fn1"><sup>1</sup></a> in it.</p></body></html>"""

        assertNull(epubNoteHtml(html, "ref1", linkedAsNoteRef = false))
    }

    @Test
    fun notesContainerItselfNavigates() {
        val html = """<html><body><section id="notes" epub:type="endnotes"><p id="n1">One.</p></section></body></html>"""

        assertNull(epubNoteHtml(html, "notes", linkedAsNoteRef = false))
        assertNotNull(epubNoteHtml(html, "n1", linkedAsNoteRef = false))
    }

    @Test
    fun docNoterefSourceMakesAnUnmarkedTargetANote() {
        val source = """<html><body><p>See<a href="notes.xhtml#x7" role="doc-noteref">7</a>.</p></body></html>"""
        val target = """<html><body><p id="x7">Unmarked note.</p></body></html>"""

        val linkedAsNoteRef = epubLinkIsNoteRef(source) { it == "notes.xhtml#x7" }

        assertTrue(linkedAsNoteRef)
        assertEquals("Unmarked note.", epubNoteHtml(target, "x7", linkedAsNoteRef))
        assertNull(epubNoteHtml(target, "x7", linkedAsNoteRef = false))
    }

    @Test
    fun ordinaryLinkIsNotANoteRef() {
        val source = """<html><body><a href="notes.xhtml#x7">Notes</a><a href="other.xhtml#x7" role="doc-noteref">7</a></body></html>"""

        assertFalse(epubLinkIsNoteRef(source) { it == "notes.xhtml#x7" })
    }
}
