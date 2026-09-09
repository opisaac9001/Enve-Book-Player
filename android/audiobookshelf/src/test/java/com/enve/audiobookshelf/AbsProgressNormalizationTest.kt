package com.enve.audiobookshelf

import com.enve.audiobookshelf.dto.AbsMediaProgressDto
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import org.junit.Assert.assertEquals
import org.junit.Test

class AbsProgressNormalizationTest {
    @Test
    fun resettingPreviouslyUnifiedAudioProgressClearsFinishedState() {
        val book = Book(id = "audio", title = "Audio", duration = 1000L,
            currentTime = 1000L, isFinished = true, readProgress = 1f, epubProgress = 1f)
        val updated = applyAbsMediaProgress(book, AbsMediaProgressDto(
            currentTime = 0.0, progress = 0f, isFinished = false, lastUpdate = 1_800_000_000_000L,
        ))
        assertEquals(0L, updated.currentTime)
        assertEquals(false, updated.isFinished)
        assertEquals(null, updated.epubProgress)
    }

    @Test
    fun ebookResetClearsOldLocator() {
        val book = Book(id = "ebook", title = "Ebook", mediaType = AppMediaType.EBOOK,
            epubProgress = 0.5f, epubLocator = "old-locator")
        val updated = applyAbsMediaProgress(book, AbsMediaProgressDto(ebookProgress = 0f))
        assertEquals(0f, updated.epubProgress)
        assertEquals(null, updated.epubLocator)
    }

    @Test
    fun explicitResetDoesNotRestoreCachedPosition() {
        assertEquals(0L, normalizeAbsCurrentTimeSeconds(0.0, 1000L, 0f, 900L))
        assertEquals(0L, normalizeAbsCurrentTimeSeconds(null, 1000L, 0f, 900L))
        assertEquals(0L, normalizeAbsCurrentTimeSeconds(0.0, 0L, null, 900L))
    }

    @Test
    fun missingProgressPreservesCachedPosition() {
        assertEquals(900L, normalizeAbsCurrentTimeSeconds(null, 1000L, null, 900L))
    }

    @Test
    fun normalizesLegacyMillisecondsAndClampsToDuration() {
        assertEquals(120L, normalizeAbsCurrentTimeSeconds(120000.0, 1000L, 0.12f, 0L))
        assertEquals(500L, normalizeAbsCurrentTimeSeconds(0.0, 1000L, 0.5f, 900L))
        assertEquals(1000L, normalizeAbsCurrentTimeSeconds(1100.0, 1000L, null, null))
    }
}
