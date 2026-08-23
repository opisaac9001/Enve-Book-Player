package com.enve.app.storyalign.export

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MediaOverlayTest {
    @Test fun smilStructure() {
        val mo = MediaOverlay(
            manifestId = "c1",
            chapterHref = "ch1.xhtml",
            basename = "ch1",
            clips = listOf(
                OverlayClip(0, 0.0, 2.5, "0000.m4a"),
                OverlayClip(1, 2.5, 5.0, "0000.m4a"),
            ),
        )
        assertEquals("c1_overlay", mo.itemId)
        assertEquals("storyalign/MediaOverlays/ch1.smil", mo.href)

        val xml = mo.overlayXml()
        assertTrue(xml.contains("epub:textref=\"../../ch1.xhtml\""))
        assertTrue(xml.contains("<par id=\"c1-sentence0\">"))
        assertTrue(xml.contains("<text src=\"../../ch1.xhtml#c1-sentence0\"/>"))
        assertTrue(xml.contains("<audio src=\"../../storyalign/Audio/0000.m4a\" clipBegin=\"0.000s\" clipEnd=\"2.500s\"/>"))
        assertTrue(xml.contains("clipBegin=\"2.500s\" clipEnd=\"5.000s\""))
    }

    @Test fun durationFormatting() {
        assertEquals("00:00:02.500", formatDuration(2.5))
        assertEquals("01:01:01.001", formatDuration(3661.001))
        assertEquals("2.345s", formatClip(2.3454))
    }
}
