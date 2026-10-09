package com.enve.app.data.repository

import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Test

class LibraryAudioCheckpointMergeTest {
    private val audio = Book(id = "audio", title = "Old", source = BookSource.AUDIOBOOKSHELF,
        connectionId = "one", mediaType = AppMediaType.AUDIOBOOK, duration = 1000L,
        currentTime = 240L, readProgress = 0.24f, lastReadTime = 2000L).toCachedBook(1L)

    @Test
    fun stalePositiveMetadataCannotRestampOlderProgressAsNew() {
        val incoming = audio.copy(title = "Refreshed", cachedAt = 5000L, currentTime = 120L, readProgress = 0.12f, lastReadTime = 1000L)
        val merged = incoming.preservingLocalProgress(audio)
        assertEquals("Refreshed", merged.title)
        assertEquals(5000L, merged.cachedAt)
        assertEquals(240L, merged.currentTime)
        assertEquals(0.24f, merged.readProgress)
        assertEquals(2000L, merged.lastReadTime)
    }

    @Test
    fun localZeroIsKeptAgainstStalePositiveMetadata() {
        val zero = audio.copy(currentTime = 0L, readProgress = 0f)
        val merged = audio.copy(currentTime = 120L, readProgress = 0.12f, lastReadTime = 1000L).preservingLocalProgress(zero)
        assertEquals(0L, merged.currentTime)
        assertEquals(0f, merged.readProgress)
        assertEquals(2000L, merged.lastReadTime)
    }

    @Test
    fun dirtyCheckpointWinsEvenAgainstApparentlyNewerServerMetadata() {
        val merged = audio.copy(currentTime = 600L, readProgress = 0.6f, lastReadTime = 4000L)
            .preservingLocalProgress(audio, hasPendingAudioPush = true)
        assertEquals(240L, merged.currentTime)
        assertEquals(2000L, merged.lastReadTime)
    }

    @Test
    fun checkpointWrittenDuringFetchWinsOverItsResponse() {
        val merged = audio.copy(currentTime = 120L, readProgress = 0.12f, lastReadTime = 4000L)
            .preservingLocalProgress(audio, preserveAudioCheckpoint = true)
        assertEquals(240L, merged.currentTime)
        assertEquals(2000L, merged.lastReadTime)
    }

    @Test
    fun acknowledgedCheckpointAllowsGenuinelyNewerRemoteZero() {
        val merged = audio.copy(currentTime = 0L, readProgress = 0f, lastReadTime = 4000L)
            .preservingLocalProgress(audio)
        assertEquals(0L, merged.currentTime)
        assertEquals(0f, merged.readProgress)
        assertEquals(4000L, merged.lastReadTime)
    }
}
