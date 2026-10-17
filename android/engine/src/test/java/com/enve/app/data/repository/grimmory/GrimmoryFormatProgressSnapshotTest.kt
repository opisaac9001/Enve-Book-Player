package com.enve.app.data.repository.grimmory

import com.enve.app.data.remote.dto.AudiobookProgressDto
import com.enve.app.data.remote.dto.EbookProgressObjectDto
import com.enve.app.data.remote.dto.GrimmoryAppBookProgressDto
import com.enve.app.data.remote.dto.GrimmoryKoreaderProgressDto
import com.enve.app.data.remote.dto.PageProgressDto
import com.enve.core.reader.EpubBridgeCheckpointCodec
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GrimmoryFormatProgressSnapshotTest {

    @Test
    fun mirrored_koreader_audio_progress_does_not_fabricate_ebook_progress() {
        val body = GrimmoryAppBookProgressDto(
            readProgress = 1f,
            readStatus = "READ",
            audiobookProgress = AudiobookProgressDto(percentage = 100f, positionMs = 60_000L),
            koreaderProgress = GrimmoryKoreaderProgressDto(percentage = 1f),
        )
        assertNull(grimmoryEbookProgressSnapshot(body, updatedAtMs = null))
    }

    @Test
    fun mirrored_koreader_progress_does_not_disable_single_format_mark_read() {
        val body = GrimmoryAppBookProgressDto(
            readStatus = "READ",
            koreaderProgress = GrimmoryKoreaderProgressDto(percentage = 1f),
        )
        val snapshot = requireNotNull(grimmoryAudiobookProgressSnapshot(body, updatedAtMs = null))
        assertTrue(snapshot.finished)
        assertEquals(1f, snapshot.percentage, 0.0001f)
    }

    private val completedEpub = EbookProgressObjectDto(percentage = 100f, cfi = CFI)

    @Test
    fun completed_epub_does_not_fabricate_an_audiobook_snapshot() {
        val body = GrimmoryAppBookProgressDto(
            readProgress = 1f,
            readStatus = "READ",
            epubProgress = completedEpub,
        )
        assertNull(grimmoryAudiobookProgressSnapshot(body, updatedAtMs = null))
    }

    @Test
    fun explicit_zero_audiobook_progress_with_completed_epub_yields_no_snapshot() {
        val body = GrimmoryAppBookProgressDto(
            readProgress = 1f,
            readStatus = "READ",
            epubProgress = completedEpub,
            audiobookProgress = AudiobookProgressDto(percentage = 0f, positionMs = 0L),
        )
        assertNull(grimmoryAudiobookProgressSnapshot(body, updatedAtMs = null))
    }

    @Test
    fun partial_audiobook_progress_is_not_finished_by_the_completed_epub() {
        val body = GrimmoryAppBookProgressDto(
            readProgress = 1f,
            readStatus = "READ",
            epubProgress = completedEpub,
            audiobookProgress = AudiobookProgressDto(percentage = 50f, positionMs = 30_000L),
        )
        val snapshot = requireNotNull(grimmoryAudiobookProgressSnapshot(body, updatedAtMs = null))
        assertEquals(0.5f, snapshot.percentage, 0.0001f)
        assertFalse(snapshot.finished)
    }

    @Test
    fun genuine_audiobook_completion_stays_finished() {
        val body = GrimmoryAppBookProgressDto(
            readProgress = 1f,
            readStatus = "READ",
            epubProgress = EbookProgressObjectDto(percentage = 40f, cfi = CFI),
            audiobookProgress = AudiobookProgressDto(percentage = 100f, positionMs = 60_000L),
        )
        val snapshot = requireNotNull(grimmoryAudiobookProgressSnapshot(body, updatedAtMs = null))
        assertEquals(1f, snapshot.percentage, 0.0001f)
        assertTrue(snapshot.finished)
    }

    @Test
    fun global_progress_still_resumes_audiobooks_without_format_progress() {
        val body = GrimmoryAppBookProgressDto(readProgress = 40f, readStatus = "READING")
        val snapshot = requireNotNull(grimmoryAudiobookProgressSnapshot(body, updatedAtMs = null))
        assertEquals(0.4f, snapshot.percentage, 0.0001f)
        assertFalse(snapshot.finished)
    }

    @Test
    fun global_read_status_alone_still_finishes_a_single_format_audiobook() {
        val body = GrimmoryAppBookProgressDto(readStatus = "READ")
        val snapshot = requireNotNull(grimmoryAudiobookProgressSnapshot(body, updatedAtMs = null))
        assertEquals(1f, snapshot.percentage, 0.0001f)
        assertTrue(snapshot.finished)
    }

    @Test
    fun completed_audiobook_does_not_fabricate_an_ebook_snapshot() {
        val body = GrimmoryAppBookProgressDto(
            readProgress = 1f,
            readStatus = "READ",
            audiobookProgress = AudiobookProgressDto(percentage = 100f, positionMs = 60_000L),
        )
        assertNull(grimmoryEbookProgressSnapshot(body, updatedAtMs = null))
    }

    @Test
    fun partial_epub_progress_is_not_finished_by_the_completed_audiobook() {
        val body = GrimmoryAppBookProgressDto(
            readProgress = 1f,
            readStatus = "READ",
            epubProgress = EbookProgressObjectDto(percentage = 37f, cfi = CFI, href = "chapter.xhtml"),
            audiobookProgress = AudiobookProgressDto(percentage = 100f, positionMs = 60_000L),
        )
        val snapshot = requireNotNull(grimmoryEbookProgressSnapshot(body, updatedAtMs = null))
        assertEquals(0.37f, snapshot.percentage, 0.0001f)
        assertEquals(CFI, snapshot.epubCfi)
        assertEquals("chapter.xhtml", snapshot.href)
        assertFalse(snapshot.finished)
    }

    @Test
    fun completed_epub_stays_finished_with_audio_progress_present() {
        val body = GrimmoryAppBookProgressDto(
            readProgress = 1f,
            readStatus = "READ",
            epubProgress = completedEpub,
            audiobookProgress = AudiobookProgressDto(percentage = 50f, positionMs = 30_000L),
        )
        val snapshot = requireNotNull(grimmoryEbookProgressSnapshot(body, updatedAtMs = null))
        assertEquals(1f, snapshot.percentage, 0.0001f)
        assertTrue(snapshot.finished)
    }

    @Test
    fun global_progress_still_resumes_ebooks_without_audio_progress() {
        val body = GrimmoryAppBookProgressDto(readProgress = 40f, readStatus = "READING")
        val snapshot = requireNotNull(grimmoryEbookProgressSnapshot(body, updatedAtMs = null))
        assertEquals(0.4f, snapshot.percentage, 0.0001f)
    }

    @Test
    fun page_based_progress_keeps_its_locator() {
        val body = GrimmoryAppBookProgressDto(
            pdfProgress = PageProgressDto(percentage = 25f, page = 3),
            audiobookProgress = AudiobookProgressDto(percentage = 80f, positionMs = 48_000L),
        )
        val snapshot = requireNotNull(grimmoryEbookProgressSnapshot(body, updatedAtMs = null))
        assertEquals(0.25f, snapshot.percentage, 0.0001f)
        assertEquals("{\"page\":3}", snapshot.locatorJson)
    }

    @Test
    fun single_file_audiobook_position_stays_global() {
        val ab = AudiobookProgressDto(percentage = 26.6667f, positionMs = 16_000L)
        assertEquals(16_000L, grimmoryGlobalAudiobookPositionMs(ab, trackStartsByIndex = null))
    }

    @Test
    fun track_relative_position_is_globalized_with_track_starts() {
        val ab = AudiobookProgressDto(percentage = 50f, positionMs = 4_000L, trackIndex = 2)
        val starts = mapOf(0 to 0L, 1 to 10_000L, 2 to 20_000L)
        assertEquals(24_000L, grimmoryGlobalAudiobookPositionMs(ab, starts))
    }

    @Test
    fun track_relative_position_without_track_starts_is_dropped() {
        val ab = AudiobookProgressDto(percentage = 50f, positionMs = 4_000L, trackIndex = 2)
        assertNull(grimmoryGlobalAudiobookPositionMs(ab, trackStartsByIndex = null))
    }

    @Test
    fun kobo_synced_progress_restores_the_chapter_and_its_progression() {
        val body = GrimmoryAppBookProgressDto(
            epubProgress = EbookProgressObjectDto(percentage = 42f, href = KOBO_HREF),
        )
        val snapshot = requireNotNull(grimmoryEbookProgressSnapshot(body, updatedAtMs = 5L))
        assertNull(snapshot.epubCfi)

        val positioned = grimmoryPositionedEbookSnapshot(
            snapshot,
            appHref = KOBO_HREF,
            detail = EbookProgressObjectDto(percentage = 42f, href = KOBO_HREF, contentSourceProgressPercent = 37.5f),
        )

        assertEquals(KOBO_HREF, positioned.href)
        assertNull(positioned.epubCfi)
        val checkpoint = requireNotNull(
            EpubBridgeCheckpointCodec.fromReadiumLocator(
                locatorJson = requireNotNull(positioned.locatorJson),
                publicationSha256 = "sha",
                providerFileId = null,
                writerEpoch = 1,
                revision = 0,
                observedAt = 5L,
            ),
        )
        assertEquals(KOBO_HREF, checkpoint.href)
        assertEquals(0.375, checkpoint.resourceProgression!!, 0.0001)
        assertEquals(0.42, checkpoint.totalProgression!!, 0.0001)
        assertEquals(0.42f, positioned.percentage, 0.0001f)
    }

    @Test
    fun file_level_cfi_wins_over_chapter_progression() {
        val snapshot = requireNotNull(
            grimmoryEbookProgressSnapshot(
                GrimmoryAppBookProgressDto(epubProgress = EbookProgressObjectDto(percentage = 10f, href = KOBO_HREF)),
                updatedAtMs = null,
            ),
        )
        val positioned = grimmoryPositionedEbookSnapshot(
            snapshot,
            appHref = null,
            detail = EbookProgressObjectDto(href = KOBO_HREF, cfi = CFI, contentSourceProgressPercent = 50f),
        )
        assertEquals(CFI, positioned.epubCfi)
        assertNull(positioned.locatorJson)
    }

    @Test
    fun chapter_progression_from_another_file_or_without_href_is_ignored() {
        val snapshot = requireNotNull(
            grimmoryEbookProgressSnapshot(
                GrimmoryAppBookProgressDto(epubProgress = EbookProgressObjectDto(percentage = 10f, href = KOBO_HREF)),
                updatedAtMs = null,
            ),
        )
        assertEquals(
            snapshot,
            grimmoryPositionedEbookSnapshot(
                snapshot,
                appHref = KOBO_HREF,
                detail = EbookProgressObjectDto(href = "OEBPS/other.xhtml", contentSourceProgressPercent = 50f),
            ),
        )
        assertEquals(
            snapshot,
            grimmoryPositionedEbookSnapshot(
                snapshot,
                appHref = KOBO_HREF,
                detail = EbookProgressObjectDto(contentSourceProgressPercent = 50f),
            ),
        )
        assertEquals(
            snapshot,
            grimmoryPositionedEbookSnapshot(
                snapshot,
                appHref = KOBO_HREF,
                detail = EbookProgressObjectDto(href = KOBO_HREF),
            ),
        )
    }

    private companion object {
        const val CFI = "epubcfi(/6/2!/4/2/2)"
        const val KOBO_HREF = "OEBPS/Text/chapter03.xhtml"
    }
}
