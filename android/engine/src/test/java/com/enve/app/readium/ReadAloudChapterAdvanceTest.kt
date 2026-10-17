package com.enve.app.readium

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadAloudChapterAdvanceTest {
    private fun clip(textHref: String, begin: Long = 0L, skippable: Boolean = false) =
        SmilClip(textHref = textHref, textFragmentId = null, audioHref = "audio.mp3", clipBeginMs = begin, clipEndMs = begin + 1_000L, skippable = skippable)

    @Test
    fun positiveSyncOffsetDoesNotCutTheLastClipOfAnAudioFile() {
        val action = readAloudClipEndAction(
            playerPositionMs = 9_000L,
            highlightPositionMs = 10_000L,
            clipEndMs = 10_000L,
            continuesInSameAudio = false,
        )

        assertEquals(ReadAloudClipEndAction.NONE, action)
    }

    @Test
    fun lastClipAdvancesWhenTheAudioReachesItsEnd() {
        val action = readAloudClipEndAction(
            playerPositionMs = 9_980L,
            highlightPositionMs = 10_980L,
            clipEndMs = 10_000L,
            continuesInSameAudio = false,
        )

        assertEquals(ReadAloudClipEndAction.ADVANCE_PLAYBACK, action)
    }

    @Test
    fun positiveSyncOffsetLeadsTheHighlightWithinTheSameAudio() {
        val action = readAloudClipEndAction(
            playerPositionMs = 9_000L,
            highlightPositionMs = 10_000L,
            clipEndMs = 10_000L,
            continuesInSameAudio = true,
        )

        assertEquals(ReadAloudClipEndAction.ADVANCE_HIGHLIGHT, action)
    }

    @Test
    fun negativeSyncOffsetStillLeavesTheClipWhenTheAudioEnds() {
        val action = readAloudClipEndAction(
            playerPositionMs = 10_000L,
            highlightPositionMs = 9_000L,
            clipEndMs = 10_000L,
            continuesInSameAudio = false,
        )

        assertEquals(ReadAloudClipEndAction.ADVANCE_PLAYBACK, action)
    }

    @Test
    fun clipWithoutKnownEndWaitsForThePlayer() {
        assertEquals(
            ReadAloudClipEndAction.NONE,
            readAloudClipEndAction(50_000L, 50_000L, clipEndMs = null, continuesInSameAudio = false),
        )
    }

    @Test
    fun advancePassesChaptersWithoutUsableClips() = runBlocking {
        val chapters = mapOf(
            "ch11.xhtml" to emptyList(),
            "ch12.xhtml" to listOf(clip("ch12.xhtml", skippable = true)),
            "ch13.xhtml" to listOf(clip("ch13.xhtml", skippable = true), clip("ch13.xhtml", begin = 1_000L)),
        )

        val start = firstNarratedStart(
            candidates = chapters.keys.toList(),
            clipsOf = { chapters.getValue(it) },
            startIndexIn = { clips -> clips.indices.firstOrNull { !clips[it].skippable } },
        )

        assertEquals("ch13.xhtml" to 1, start)
    }

    @Test
    fun advanceStopsOnlyAtTheEndOfTheBook() = runBlocking {
        val start = firstNarratedStart(
            candidates = listOf("back-matter.xhtml"),
            clipsOf = { emptyList() },
            startIndexIn = { clips -> clips.indices.firstOrNull() },
        )

        assertNull(start)
    }

    @Test
    fun skippedChapterNoticeNamesTheChapter() {
        assertNull(readAloudSkippedChapterNotice(emptyList()))
        assertEquals(
            "No narration for “Chapter 11”. Continuing with the next narrated chapter.",
            readAloudSkippedChapterNotice(listOf("Chapter 11")),
        )
        assertEquals(
            "No narration for 2 chapters. Continuing with the next narrated chapter.",
            readAloudSkippedChapterNotice(listOf("Chapter 11", "Chapter 12")),
        )
    }

    @Test
    fun overlayNarratingAnotherSpineDocumentIsRejected() {
        val spine = setOf("OEBPS/part-one/chapter.xhtml", "OEBPS/part-two/chapter.xhtml")

        assertTrue(
            readAloudOverlayBelongsElsewhere(
                textHrefs = listOf("OEBPS/part-two/chapter.xhtml"),
                spineHref = "OEBPS/part-one/chapter.xhtml",
                readingOrderHrefs = spine,
            ),
        )
        assertFalse(
            readAloudOverlayBelongsElsewhere(
                textHrefs = listOf("OEBPS/part-two/chapter.xhtml"),
                spineHref = "OEBPS/part-two/chapter.xhtml",
                readingOrderHrefs = spine,
            ),
        )
        assertFalse(
            readAloudOverlayBelongsElsewhere(
                textHrefs = listOf("chapter.xhtml"),
                spineHref = "OEBPS/part-one/chapter.xhtml",
                readingOrderHrefs = spine,
            ),
        )
    }

    @Test
    fun hrefMatchPrefersTheFullPath() {
        val hrefs = listOf("OEBPS/part-one/chapter.xhtml", "OEBPS/part-two/chapter.xhtml")

        assertEquals(1, uniqueHrefMatch(hrefs, "OEBPS/part-two/chapter.xhtml"))
    }

    @Test
    fun ambiguousBasenameDoesNotMatch() {
        val hrefs = listOf("OEBPS/part-one/chapter.xhtml", "OEBPS/part-two/chapter.xhtml")

        assertNull(uniqueHrefMatch(hrefs, "chapter.xhtml"))
    }

    @Test
    fun uniqueBasenameStillMatchesAndSuffixDoesNot() {
        val hrefs = listOf("OEBPS/Text/xchapter.xhtml", "OEBPS/Text/chapter.xhtml")

        assertEquals(1, uniqueHrefMatch(hrefs, "Text/chapter.xhtml"))
        assertNull(uniqueHrefMatch(listOf("OEBPS/Text/xchapter.xhtml"), "chapter.xhtml"))
    }
}
