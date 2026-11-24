package com.enve.core.data.local

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import java.nio.file.Files
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class PodcastFeedProgressImportTest {
    @Test
    fun importDoesNotOverwritePlaybackThatChangedAfterPreview() = runBlocking {
        val directory = Files.createTempDirectory("podcast-import").toFile()
        val job = SupervisorJob()
        val dataStore = PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) {
            directory.resolve("progress.preferences_pb")
        }
        val store = PodcastFeedProgressStore(dataStore)
        try {
            val old = PodcastFeedProgress(10, 100, false, 100)
            store.save("episode-a", old)
            val expected = store.all()
            val rewind = old.copy(positionSec = 5, updatedAtMs = 300)
            store.save("episode-a", rewind)
            val imported = old.copy(positionSec = 80, updatedAtMs = 200)
            assertEquals(1, store.saveImported(expected, mapOf("episode-a" to imported, "episode-b" to imported)))
            assertEquals(rewind, store.all()["episode-a"])
            assertEquals(imported, store.all()["episode-b"])
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }
}
