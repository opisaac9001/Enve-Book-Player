package com.enve.app.playback

import com.enve.app.data.remote.dto.AudiobookProgressDto
import com.enve.app.data.remote.dto.EbookProgressObjectDto
import com.enve.app.data.remote.dto.GrimmoryAppBookProgressDto
import com.enve.app.data.repository.grimmory.grimmoryAudiobookProgressSnapshot
import com.enve.app.data.repository.grimmory.grimmoryGlobalAudiobookPositionMs
import com.enve.app.data.sync.ProgressResolutionPolicy
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.sync.SyncSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackOpenProgressDecisionTest {

    @Test
    fun cold_cache_ebook_primary_resumes_audio_from_remote_sixteen_seconds() {
        val book = grimmoryEntity(
            mediaType = AppMediaType.EBOOK,
            readProgress = 1f,
            epubLocator = CFI,
            lastReadTime = EBOOK_UPDATED_AT,
        ).forAudioPlayback()

        assertNull(audioLocalUpdatedAt(book))
        assertEquals(0f, audioLocalPercentage(book), 0.0001f)
        assertEquals(0L, audioLocalStartSeconds(book))

        val snapshot = requireNotNull(audiobookSnapshot(mixedFormatBody(16_000L, 26.6667f), AUDIO_UPDATED_AT))
        assertEquals(16_000L, snapshot.positionMs)
        assertEquals(ProgressResolutionPolicy.Decision.PULL, decisionFor(book, snapshot))
        assertEquals(16L, openStartSeconds(book, snapshot))
    }

    @Test
    fun cold_cache_audio_primary_resumes_audio_from_remote_sixteen_seconds() {
        val book = grimmoryEntity(
            mediaType = AppMediaType.AUDIOBOOK,
            readProgress = 1f,
            epubLocator = CFI,
            lastReadTime = EBOOK_UPDATED_AT,
            hasEbook = true,
        )
        assertEquals(book, book.forAudioPlayback())

        assertNull(audioLocalUpdatedAt(book))
        val snapshot = requireNotNull(audiobookSnapshot(mixedFormatBody(16_000L, 26.6667f), AUDIO_UPDATED_AT))
        assertEquals(ProgressResolutionPolicy.Decision.PULL, decisionFor(book, snapshot))
        assertEquals(16L, openStartSeconds(book, snapshot))
    }

    @Test
    fun absent_audio_progress_opens_from_the_beginning() {
        val book = grimmoryEntity(
            mediaType = AppMediaType.EBOOK,
            readProgress = 1f,
            epubLocator = CFI,
        ).forAudioPlayback()

        val snapshot = audiobookSnapshot(
            GrimmoryAppBookProgressDto(readProgress = 1f, readStatus = "READ", epubProgress = completedEpub),
            AUDIO_UPDATED_AT,
        )
        assertNull(snapshot)
        assertEquals(0L, openStartSeconds(book, snapshot))
    }

    @Test
    fun explicit_zero_audio_progress_opens_from_the_beginning() {
        val book = grimmoryEntity(
            mediaType = AppMediaType.EBOOK,
            readProgress = 1f,
            epubLocator = CFI,
        ).forAudioPlayback()

        val snapshot = audiobookSnapshot(
            GrimmoryAppBookProgressDto(
                readProgress = 1f,
                readStatus = "READ",
                epubProgress = completedEpub,
                audiobookProgress = AudiobookProgressDto(percentage = 0f, positionMs = 0L),
            ),
            AUDIO_UPDATED_AT,
        )
        assertNull(snapshot)
        assertEquals(0L, openStartSeconds(book, snapshot))
    }

    @Test
    fun genuine_remote_audio_completion_resumes_at_the_end() {
        val book = grimmoryEntity(
            mediaType = AppMediaType.EBOOK,
            readProgress = 1f,
            epubLocator = CFI,
        ).forAudioPlayback()

        val snapshot = requireNotNull(
            audiobookSnapshot(
                GrimmoryAppBookProgressDto(
                    readProgress = 1f,
                    readStatus = "READ",
                    epubProgress = EbookProgressObjectDto(percentage = 40f, cfi = CFI),
                    audiobookProgress = AudiobookProgressDto(percentage = 100f, positionMs = 60_000L),
                ),
                AUDIO_UPDATED_AT,
            ),
        )
        assertTrue(snapshot.finished)
        assertEquals(ProgressResolutionPolicy.Decision.PULL, decisionFor(book, snapshot))
        assertEquals(60L, openStartSeconds(book, snapshot))
    }

    @Test
    fun single_format_audiobook_resumes_from_remote_when_local_is_absent() {
        val book = grimmoryEntity(mediaType = AppMediaType.AUDIOBOOK, duration = 60L)

        val snapshot = requireNotNull(
            audiobookSnapshot(
                GrimmoryAppBookProgressDto(
                    readStatus = "READING",
                    audiobookProgress = AudiobookProgressDto(percentage = 26.6667f, positionMs = 16_000L),
                ),
                AUDIO_UPDATED_AT,
            ),
        )
        assertEquals(ProgressResolutionPolicy.Decision.PULL, decisionFor(book, snapshot))
        assertEquals(16L, openStartSeconds(book, snapshot))
    }

    @Test
    fun single_format_audiobook_keeps_its_local_percentage_when_remote_is_absent() {
        val book = grimmoryEntity(mediaType = AppMediaType.AUDIOBOOK, readProgress = 0.5f, duration = 60L)

        val snapshot = audiobookSnapshot(GrimmoryAppBookProgressDto(), AUDIO_UPDATED_AT)
        assertNull(snapshot)
        assertEquals(30L, openStartSeconds(book, snapshot))
    }

    private fun audiobookSnapshot(body: GrimmoryAppBookProgressDto, updatedAtMs: Long?): SyncSnapshot? {
        val snapshot = grimmoryAudiobookProgressSnapshot(body = body, updatedAtMs = updatedAtMs) ?: return null
        return snapshot.copy(positionMs = grimmoryGlobalAudiobookPositionMs(body.audiobookProgress, trackStartsByIndex = null))
    }

    private fun decisionFor(book: Book, snapshot: SyncSnapshot): ProgressResolutionPolicy.Decision =
        ProgressResolutionPolicy.resolve(audioLocalPercentage(book), audioLocalUpdatedAt(book), snapshot)

    private fun openStartSeconds(book: Book, snapshot: SyncSnapshot?): Long {
        val localStart = audioLocalStartSeconds(book)
        snapshot ?: return localStart
        return if (decisionFor(book, snapshot) == ProgressResolutionPolicy.Decision.PULL) {
            remoteStartSeconds(snapshot.positionMs, snapshot.percentage, book.duration)
        } else {
            localStart
        }
    }

    private fun mixedFormatBody(positionMs: Long, percentage: Float) = GrimmoryAppBookProgressDto(
        readProgress = 1f,
        readStatus = "READ",
        epubProgress = completedEpub,
        audiobookProgress = AudiobookProgressDto(percentage = percentage, positionMs = positionMs),
    )

    private fun grimmoryEntity(
        mediaType: AppMediaType,
        readProgress: Float = 0f,
        duration: Long = 0L,
        currentTime: Long = 0L,
        epubLocator: String? = null,
        lastReadTime: Long = 0L,
        hasEbook: Boolean = false,
    ) = Book(
        id = "30280",
        title = "Dual",
        source = BookSource.GRIMMORY,
        mediaType = mediaType,
        connectionId = "lab",
        duration = duration,
        currentTime = currentTime,
        readProgress = readProgress,
        epubLocator = epubLocator,
        lastReadTime = lastReadTime,
        hasEbook = hasEbook,
    )

    private val completedEpub = EbookProgressObjectDto(percentage = 100f, cfi = CFI)

    private companion object {
        const val CFI = "epubcfi(/6/2!/4/2/2)"
        const val AUDIO_UPDATED_AT = 1_000L
        const val EBOOK_UPDATED_AT = 5_000L
    }
}
