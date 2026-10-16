package com.enve.core.data.local

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.nio.file.Files

class ComicReadingDirectionOverrideStoreTest {
    @Test
    fun overridesPersistPerBookWithoutBecomingADefaultForOtherBooks() = runBlocking {
        val directory = Files.createTempDirectory("comic-direction").toFile()
        val file = directory.resolve("settings.preferences_pb")
        var job = SupervisorJob()
        try {
            var dataStore = PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) { file }
            var store = ComicReadingDirectionOverrideStore(dataStore)
            assertNull(store.direction("komga:issue-1"))
            store.save("komga:issue-1", "RIGHT_TO_LEFT")
            store.save("komga:issue-2", "LEFT_TO_RIGHT")
            job.cancelAndJoin()

            job = SupervisorJob()
            dataStore = PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) { file }
            store = ComicReadingDirectionOverrideStore(dataStore)
            assertEquals("RIGHT_TO_LEFT", store.direction("komga:issue-1"))
            assertEquals("LEFT_TO_RIGHT", store.direction("komga:issue-2"))
            assertNull(store.direction("komga:issue-3"))
            store.save("komga:issue-4", "RIGHT_TO_LEFT")
            assertNull(store.direction("komga:issue-5"))
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    @Test
    fun clearingAnOverrideReturnsTheBookToAutomaticDirection() = runBlocking {
        val directory = Files.createTempDirectory("comic-direction-clear").toFile()
        val job = SupervisorJob()
        try {
            val dataStore = PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) {
                directory.resolve("settings.preferences_pb")
            }
            val store = ComicReadingDirectionOverrideStore(dataStore)
            store.save("komga:issue-1", "RIGHT_TO_LEFT")
            store.save("komga:issue-2", "WEBTOON")
            store.clear("komga:issue-1")
            assertNull(store.direction("komga:issue-1"))
            assertEquals("WEBTOON", store.direction("komga:issue-2"))
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }
}
