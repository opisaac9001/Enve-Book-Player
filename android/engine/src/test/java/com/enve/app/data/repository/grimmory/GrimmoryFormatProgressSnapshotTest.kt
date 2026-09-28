package com.enve.app.data.repository.grimmory

import com.enve.app.data.remote.dto.AudiobookProgressDto
import com.enve.app.data.remote.dto.EbookProgressObjectDto
import com.enve.app.data.remote.dto.GrimmoryAppBookProgressDto
import com.enve.app.data.remote.dto.GrimmoryKoreaderProgressDto
import com.enve.app.data.remote.dto.PageProgressDto
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

    private companion object {
        const val CFI = "epubcfi(/6/2!/4/2/2)"
    }
}
