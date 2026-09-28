package com.enve.app.readium

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MediaOverlayTextProgressionTest {

    private val chapterOne = """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ignored title</title><style>p { margin: 0; }</style></head>
        <body>
          <h1 id="c1h">Start</h1>
          <p><span id="c1s1">Aaaa aaaa.</span> <span id="c1s2">Bbbb &amp; bbbb.</span></p>
          <!-- a comment <span id="ghost">x</span> -->
          <script>var x = "<span id='fake'>";</script>
          <p class="x" data-id="nope" id="c1s3">Cccc cccc cccc.</p>
        </body></html>
    """.trimIndent()

    private val chapterTwo = """<html><body><p id="c2s1">One.</p><p id="c2s2">Two.</p></body></html>"""

    private val chapterStarts = listOf(0.0, 0.1, 0.5)

    private val chapterOneClips = listOf("c1s1", "c1s2", "c1s3").map(::clip)
    private val chapterTwoClips = listOf("c2s1", "missing", "c2s2").map(::clip)

    @Test
    fun countsRenderedBodyTextAndSkipsMarkupCommentsAndScripts() {
        val offsets = MediaOverlayTextProgression.fragmentOffsets(chapterOne)

        assertEquals(45, offsets.textLength)
        assertEquals(mapOf("c1h" to 0, "c1s1" to 6, "c1s2" to 17, "c1s3" to 30), offsets.offsetsById)
    }

    @Test
    fun countsMultibyteCharactersOnceAndReadsSingleQuotedIds() {
        val offsets = MediaOverlayTextProgression.fragmentOffsets("<body><p id='a'>héllo</p><p id='b'>x</p></body>")

        assertEquals(6, offsets.textLength)
        assertEquals(mapOf("a" to 0, "b" to 5), offsets.offsetsById)
    }

    @Test
    fun chapterSpanRunsFromItsFirstPositionToTheNextChapter() {
        assertEquals(0.1..0.5, MediaOverlayTextProgression.chapterSpan(chapterStarts, 1))
        assertEquals(0.5..1.0, MediaOverlayTextProgression.chapterSpan(chapterStarts, 2))
        assertNull(MediaOverlayTextProgression.chapterSpan(chapterStarts, 3))
    }

    @Test
    fun placesFragmentsNearStartMiddleAndEndOnThePositionScale() {
        val progressions = MediaOverlayTextProgression.clipProgressions(
            clips = chapterOneClips,
            span = MediaOverlayTextProgression.chapterSpan(chapterStarts, 1)!!,
            offsets = MediaOverlayTextProgression.fragmentOffsets(chapterOne),
        )

        assertEquals(0.1 + 6.0 / 45.0 * 0.4, progressions[0], 1e-9)
        assertEquals(0.1 + 17.0 / 45.0 * 0.4, progressions[1], 1e-9)
        assertEquals(0.1 + 30.0 / 45.0 * 0.4, progressions[2], 1e-9)
    }

    @Test
    fun fallsBackToClipIndexRatioForAnUnknownFragment() {
        val progressions = MediaOverlayTextProgression.clipProgressions(
            clips = chapterTwoClips,
            span = MediaOverlayTextProgression.chapterSpan(chapterStarts, 2)!!,
            offsets = MediaOverlayTextProgression.fragmentOffsets(chapterTwo),
        )

        assertEquals(0.5, progressions[0], 1e-9)
        assertEquals(0.5 + 1.0 / 3.0 * 0.5, progressions[1], 1e-9)
        assertEquals(0.75, progressions[2], 1e-9)
    }

    @Test
    fun fallsBackToClipIndexRatioWhenChapterTextIsUnavailable() {
        val progressions = MediaOverlayTextProgression.clipProgressions(
            clips = chapterOneClips,
            span = MediaOverlayTextProgression.chapterSpan(chapterStarts, 1)!!,
            offsets = null,
        )

        assertEquals(0.1, progressions[0], 1e-9)
        assertEquals(0.1 + 2.0 / 3.0 * 0.4, progressions[2], 1e-9)
    }

    @Test
    fun completedNarrationFinishesTheBookDespiteUnnarratedBackMatter() {
        val lastNarratedSentence = MediaOverlayTextProgression.clipProgressions(
            clips = chapterTwoClips,
            span = MediaOverlayTextProgression.chapterSpan(listOf(0.0, 0.1, 0.5, 0.9), 2)!!,
            offsets = MediaOverlayTextProgression.fragmentOffsets(chapterTwo),
        ).last()

        assertEquals(lastNarratedSentence, MediaOverlayTextProgression.readingProgression(lastNarratedSentence, narrationCompleted = false)!!, 0.0)
        assertEquals(1.0, MediaOverlayTextProgression.readingProgression(lastNarratedSentence, narrationCompleted = true)!!, 0.0)
        assertEquals(1.0, MediaOverlayTextProgression.readingProgression(null, narrationCompleted = true)!!, 0.0)
    }

    private fun clip(fragmentId: String) = SmilClip(
        textHref = "OEBPS/text/chapter.xhtml",
        textFragmentId = fragmentId,
        audioHref = "OEBPS/audio/chapter.mp3",
        clipBeginMs = 0L,
        clipEndMs = 1_000L,
    )
}
