package com.enve.app.playback.clips

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.engine.playback.AudiobookClip
import java.io.File
import com.enve.engine.playback.AudiobookClipException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AudiobookClipStoreTest {
    @get:Rule val temp = TemporaryFolder()

    @Test
    fun transcriptionRequiresTheOriginalClipToStillExistUnchanged() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val locations = ProfileStorageLocations.forProfile(
            profileId = "clip-test", filesDirectory = File(temp.root, "files"),
            cacheDirectory = File(temp.root, "cache"), databaseDirectory = File(temp.root, "databases"),
        )
        val store = AudiobookClipStore(context, locations)
        val original = AudiobookClip("bookmark", "book", 0, 5000, 1)
        val edited = original.copy(startMs = 1000)
        store.upsert(original)
        store.upsert(edited)

        suspend fun rejectStaleResult() {
            try {
                store.saveTranscript(original, "obsolete")
                fail("Expected stale transcript to be rejected")
            } catch (_: AudiobookClipException) {
            }
        }
        rejectStaleResult()
        assertEquals(edited, store.clip(original.bookmarkId))
        store.saveTranscript(edited, "current")
        assertEquals("current", AudiobookClipStore(context, locations).clip(edited.bookmarkId)?.transcript)

        store.delete(setOf(original.bookmarkId))
        rejectStaleResult()
        assertNull(AudiobookClipStore(context, locations).clip(original.bookmarkId))
    }
}
