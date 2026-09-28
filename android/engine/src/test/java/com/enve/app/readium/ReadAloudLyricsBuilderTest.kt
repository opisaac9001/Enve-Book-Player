package com.enve.app.readium

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ReadAloudLyricsBuilderTest {

    private val chapter =
        """
        <?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>c10A</title></head>
        <body>
        <p><span id="c10A.xhtml-s2">La silueta tambaleante me hiela la sangre.</span></p>
        <p><span id="c10A.xhtml-s3">Pablo se tambalea dentro. </span><span id="c10A.xhtml-s4">Su piel tiene un tono gris&#225;ceo.</span></p>
        <p><span id="c10A.xhtml-s9">Mira a Pablo como si entrara un extra de <span class="cite">Callejeros</span>.</span></p>
        </body></html>
        """.trimIndent()

    private fun clip(
        fragment: String?,
        href: String = "OEBPS/c10A.xhtml",
        beginMs: Long,
        endMs: Long?,
        audioHref: String = "OEBPS/Audio/00001.mp4",
    ) = SmilClip(
        textHref = href,
        textFragmentId = fragment,
        audioHref = audioHref,
        clipBeginMs = beginMs,
        clipEndMs = endMs,
    )

    @Test
    fun buildsALineForEverySentenceOfTheGivenResource() {
        val clips = listOf(
            clip("c10A.xhtml-s2", beginMs = 0, endMs = 2_000),
            clip("c10A.xhtml-s3", beginMs = 2_000, endMs = 5_000),
        )

        val lines = ReadAloudLyricsBuilder.lines(clips, chapter, "OEBPS/c10A.xhtml")

        assertEquals(listOf("c10A.xhtml-s2", "c10A.xhtml-s3"), lines.map { it.id })
        assertEquals("La silueta tambaleante me hiela la sangre.", lines[0].text)
        assertEquals(listOf(0, 1), lines.map { it.clipIndex })
        assertEquals(5_000L, lines[1].endMs)
    }

    @Test
    fun decodesEntitiesAndFlattensNestedMarkup() {
        val clips = listOf(
            clip("c10A.xhtml-s4", beginMs = 0, endMs = 1_000),
            clip("c10A.xhtml-s9", beginMs = 1_000, endMs = 2_000),
        )

        val lines = ReadAloudLyricsBuilder.lines(clips, chapter, "OEBPS/c10A.xhtml")

        assertEquals("Su piel tiene un tono grisáceo.", lines[0].text)
        assertEquals("Mira a Pablo como si entrara un extra de Callejeros.", lines[1].text)
    }

    @Test
    fun skipsClipsFromOtherResourcesAndOnesWithoutText() {
        val clips = listOf(
            clip("c10A.xhtml-s2", beginMs = 0, endMs = 1_000),
            clip("other.xhtml-s0", href = "OEBPS/other.xhtml", beginMs = 1_000, endMs = 2_000),
            clip("c10A.xhtml-missing", beginMs = 2_000, endMs = 3_000),
            clip(null, beginMs = 3_000, endMs = 4_000),
        )

        val lines = ReadAloudLyricsBuilder.lines(clips, chapter, "OEBPS/c10A.xhtml")

        assertEquals(listOf("c10A.xhtml-s2"), lines.map { it.id })
    }

    @Test
    fun matchesResourcesThatDifferOnlyByDirectoryPrefix() {
        val clips = listOf(clip("c10A.xhtml-s2", href = "c10A.xhtml", beginMs = 0, endMs = 1_000))

        val lines = ReadAloudLyricsBuilder.lines(clips, chapter, "OEBPS/c10A.xhtml")

        assertEquals(1, lines.size)
    }

    @Test
    fun activeLineTracksThePlaybackPosition() {
        val clips = listOf(
            clip("c10A.xhtml-s2", beginMs = 0, endMs = 2_000),
            clip("c10A.xhtml-s3", beginMs = 2_000, endMs = 5_000),
            clip("c10A.xhtml-s4", beginMs = 5_000, endMs = 9_000),
        )
        val lines = ReadAloudLyricsBuilder.lines(clips, chapter, "OEBPS/c10A.xhtml")

        assertEquals("c10A.xhtml-s2", ReadAloudLyricsBuilder.activeLineId(lines, 0))
        assertEquals("c10A.xhtml-s3", ReadAloudLyricsBuilder.activeLineId(lines, 3_200))
        assertEquals("c10A.xhtml-s4", ReadAloudLyricsBuilder.activeLineId(lines, 20_000))
    }

    @Test
    fun activeLineFallsBackToTheFirstBeforeNarrationReachesIt() {
        val clips = listOf(clip("c10A.xhtml-s2", beginMs = 4_000, endMs = 6_000))
        val lines = ReadAloudLyricsBuilder.lines(clips, chapter, "OEBPS/c10A.xhtml")

        assertEquals("c10A.xhtml-s2", ReadAloudLyricsBuilder.activeLineId(lines, 0))
        assertNull(ReadAloudLyricsBuilder.activeLineId(emptyList(), 0))
    }

    @Test
    fun offsetsAccumulateInTrackOrderAndIgnoreRepeats() {
        val offsets = ReadAloudLyricsBuilder.audioOffsetsMs(
            listOf(
                "OEBPS/Audio/00001.mp4" to 10_000L,
                "OEBPS/Audio/00002.mp4" to 7_500L,
                "OEBPS/Audio/00001.mp4" to 10_000L,
                "OEBPS/Audio/00003.mp4" to 4_000L,
            )
        )

        assertEquals(0L, offsets["00001.mp4"])
        assertEquals(10_000L, offsets["00002.mp4"])
        assertEquals(17_500L, offsets["00003.mp4"])
    }

    @Test
    fun clipTimesAreLiftedOntoTheGlobalTimelineForMultiFileNarration() {
        val offsets = ReadAloudLyricsBuilder.audioOffsetsMs(
            listOf("OEBPS/Audio/00001.mp4" to 10_000L, "OEBPS/Audio/00002.mp4" to 9_000L)
        )
        val clips = listOf(
            clip("c10A.xhtml-s2", beginMs = 1_000, endMs = 3_000),
            clip("c10A.xhtml-s3", beginMs = 2_000, endMs = 6_000, audioHref = "OEBPS/Audio/00002.mp4"),
        )

        val lines = ReadAloudLyricsBuilder.lines(clips, chapter, "OEBPS/c10A.xhtml", offsets)

        assertEquals(1_000L, lines[0].startMs)
        assertEquals(12_000L, lines[1].startMs)
        assertEquals(16_000L, lines[1].endMs)
        assertEquals("c10A.xhtml-s3", ReadAloudLyricsBuilder.activeLineId(lines, 13_500))
        assertEquals("c10A.xhtml-s2", ReadAloudLyricsBuilder.activeLineId(lines, 2_000))
    }
}
