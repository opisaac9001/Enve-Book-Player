package com.enve.app.playback

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlaybackLocalStartSecondsTest {

    @Test
    fun ebook_timestamp_cannot_make_absent_local_audio_progress_win() {
        val book = grimmoryAudiobook(readProgress = 1f, hasEbook = true).copy(lastReadTime = 2000L)
        assertNull(audioLocalUpdatedAt(book))
        assertEquals(2000L, audioLocalUpdatedAt(book.copy(currentTime = 30L)))
    }

    @Test
    fun ebook_primary_audio_sessions_keep_identity_but_use_audio_progress_routing() {
        val ebook = grimmoryAudiobook().copy(mediaType = AppMediaType.EBOOK, connectionId = "lab")
        val audio = ebook.forAudioPlayback()
        assertEquals(ebook.uniqueKey, audio.uniqueKey)
        assertEquals(AppMediaType.AUDIOBOOK, audio.mediaType)
        assertEquals(true, audio.hasEbook)
        assertEquals(true, audio.hasAudio)
        assertEquals(ebook.mediaType, AppMediaType.EBOOK)
    }

    @Test
    fun audio_normalization_preserves_podcast_type_and_audio_position() {
        val audio = grimmoryAudiobook(currentTime = 30L)
        assertEquals(audio, audio.forAudioPlayback())
        val podcast = audio.copy(mediaType = AppMediaType.PODCAST)
        assertEquals(podcast, podcast.forAudioPlayback())
    }

    private fun grimmoryAudiobook(
        currentTime: Long = 0L,
        readProgress: Float = 0f,
        hasEbook: Boolean = false,
        epubLocator: String? = null,
    ) = Book(
        id = "1",
        title = "Dual",
        source = BookSource.GRIMMORY,
        mediaType = AppMediaType.AUDIOBOOK,
        duration = 60L,
        currentTime = currentTime,
        readProgress = readProgress,
        hasEbook = hasEbook,
        epubLocator = epubLocator,
    )

    @Test
    fun dual_format_entity_percentage_does_not_become_an_audio_position() {
        val book = grimmoryAudiobook(readProgress = 1f, hasEbook = true)
        assertEquals(0L, audioLocalStartSeconds(book))
        assertEquals(0f, audioLocalPercentage(book), 0.0001f)
    }

    @Test
    fun stale_format_flags_are_covered_by_the_stored_epub_locator() {
        val book = grimmoryAudiobook(readProgress = 1f, epubLocator = "epubcfi(/6/2!/4/2/2)")
        assertEquals(0L, audioLocalStartSeconds(book))
        assertEquals(0f, audioLocalPercentage(book), 0.0001f)
    }

    @Test
    fun a_real_audio_position_wins_over_the_cross_format_guard() {
        val book = grimmoryAudiobook(currentTime = 30L, readProgress = 1f, hasEbook = true)
        assertEquals(30L, audioLocalStartSeconds(book))
        assertEquals(0.5f, audioLocalPercentage(book), 0.0001f)
    }

    @Test
    fun single_format_grimmory_audiobooks_still_resume_from_percentage() {
        val book = grimmoryAudiobook(readProgress = 0.5f)
        assertEquals(30L, audioLocalStartSeconds(book))
        assertEquals(0.5f, audioLocalPercentage(book), 0.0001f)
    }

    @Test
    fun other_sources_keep_the_percentage_fallback() {
        val book = grimmoryAudiobook(readProgress = 0.5f, hasEbook = true)
            .copy(source = BookSource.AUDIOBOOKSHELF)
        assertEquals(30L, audioLocalStartSeconds(book))
        assertEquals(0.5f, audioLocalPercentage(book), 0.0001f)
    }

    @Test
    fun positions_clamp_to_duration() {
        val book = grimmoryAudiobook(currentTime = 90L)
        assertEquals(60L, audioLocalStartSeconds(book))
    }
}
