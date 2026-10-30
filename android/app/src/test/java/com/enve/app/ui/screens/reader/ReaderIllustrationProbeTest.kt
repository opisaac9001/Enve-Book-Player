package com.enve.app.ui.screens.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderIllustrationProbeTest {
    @Test
    fun nothingUnderTheFingerIsNoHit() {
        assertNull(ReaderIllustrationProbe.parse(null))
        assertNull(ReaderIllustrationProbe.parse(""))
        assertNull(ReaderIllustrationProbe.parse("null"))
        assertNull(ReaderIllustrationProbe.parse("undefined"))
        assertNull(ReaderIllustrationProbe.parse("{\"alt\":\"orphan\"}"))
        assertNull(ReaderIllustrationProbe.parse("not json"))
    }

    @Test
    fun aHitCarriesTheResourceAndItsDescriptions() {
        val hit = ReaderIllustrationProbe.parse(
            """{"src":"../images/map.jpg","resource":"OEBPS/images/map.jpg","alt":"Map of the realm","caption":"Fig. 1","width":1800,"height":1200,"linked":false}""",
        )
        checkNotNull(hit)
        assertEquals("../images/map.jpg", hit.src)
        assertEquals("OEBPS/images/map.jpg", hit.resource)
        assertEquals("Map of the realm", hit.alt)
        assertEquals("Fig. 1", hit.caption)
        assertEquals(1800, hit.width)
        assertFalse(hit.linked)
    }

    @Test
    fun aQuotedJsonAnswerIsUnwrappedFirst() {
        val hit = ReaderIllustrationProbe.parse("\"{\\\"src\\\":\\\"plate.png\\\"}\"")
        assertEquals("plate.png", checkNotNull(hit).src)
    }

    @Test
    fun aLinkedImageIsReportedSoTheTapIsLeftToTheLink() {
        val hit = ReaderIllustrationProbe.parse("""{"linked":true}""")
        assertTrue(checkNotNull(hit).linked)
        assertNull(hit.src)
    }

    @Test
    fun engineWrappersHandTheProbeTheDocumentAndPoint() {
        assertEquals("(${ReaderIllustrationProbe.SCRIPT})(document, 12.5, 40.0);", ReaderIllustrationProbe.readiumScript(12.5f, 40f))
        assertTrue(ReaderIllustrationProbe.foliateScript(1f, 2f).startsWith("window.enveReader.illustrationAt(1.0, 2.0, (function (doc, x, y) {"))
    }

    @Test
    fun probeRespectsLinksSelectionAndOnlyPublicationResources() {
        val script = ReaderIllustrationProbe.SCRIPT
        assertTrue(script.contains("image.closest(\"a[href]\")"))
        assertTrue(script.contains("return { linked: true }"))
        assertTrue(script.contains("!selection.isCollapsed) return null"))
        assertTrue(script.contains("doc.elementFromPoint(x, y)"))
        assertTrue(script.contains("data-enve-resource"))
        assertTrue(script.contains("if (!resource && (!src || /^(data|blob):/i.test(src))) return null"))
        assertFalse(script.contains("fetch("))
        assertFalse(script.contains("btoa"))
        assertFalse(script.contains("JSON.stringify"))
    }

    @Test
    fun probeSkipsOrnamentsAndReadsTheBooksOwnCaption() {
        val script = ReaderIllustrationProbe.SCRIPT
        assertTrue(script.contains("rect.width < ${ReaderIllustrationProbe.MIN_RENDERED_CSS_PX}"))
        assertTrue(script.contains("Math.max(width, height) < ${ReaderIllustrationProbe.MIN_NATURAL_PX}"))
        assertTrue(script.contains("target.closest(\"figure\")"))
        assertTrue(script.contains("querySelector(\"figcaption\")"))
        assertTrue(script.contains("getAttribute(\"alt\")"))
        assertTrue(script.contains("references.length !== 1) return null"))
    }
}
