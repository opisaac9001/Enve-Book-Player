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
    fun manualDirectionPersistsForNewIssuesWithoutReplacingBookOverrides() = runBlocking {
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
            assertEquals("LEFT_TO_RIGHT", store.direction("komga:issue-3"))
            assertEquals("RIGHT_TO_LEFT", store.direction("komga:issue-1") { error("A manual override must not fetch the server") })
            assertEquals("RIGHT_TO_LEFT", store.direction("komga:issue-3") { "RIGHT_TO_LEFT" })
            assertEquals("LEFT_TO_RIGHT", store.direction("komga:issue-4") { "LEFT_TO_RIGHT" })
            store.save("komga:issue-5", "RIGHT_TO_LEFT")
            assertEquals("LEFT_TO_RIGHT", store.direction("komga:issue-6") { "LEFT_TO_RIGHT" })
            assertEquals("RIGHT_TO_LEFT", store.direction("komga:issue-6"))
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }
}
