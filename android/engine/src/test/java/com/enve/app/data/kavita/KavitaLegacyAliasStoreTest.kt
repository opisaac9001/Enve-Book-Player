package com.enve.app.data.kavita

import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

class KavitaLegacyAliasStoreTest {
    private val root: File = Files.createTempDirectory("kavita-alias").toFile()

    @After
    fun cleanUp() {
        root.deleteRecursively()
    }

    private fun store(profileId: String = DEFAULT_ADULT_PROFILE_ID) = KavitaLegacyAliasStore(
        ProfileStorageLocations.forProfile(
            profileId = profileId,
            filesDirectory = File(root, "files"),
            cacheDirectory = File(root, "cache"),
            databaseDirectory = File(root, "databases"),
        ),
    )

    @Test
    fun pinSurvivesServerReorderingAndProcessRestart() = runBlocking {
        assertEquals(mapOf(28 to 54), store().pin("connection-a", mapOf(28 to 54)))

        val restarted = store()
        assertEquals(mapOf(28 to 54), restarted.pin("connection-a", mapOf(28 to 55)))
        assertEquals(mapOf(28 to 54), restarted.pin("connection-a", mapOf(28 to null)))
    }

    @Test
    fun seriesWithoutCandidateStaysUnpinnedUntilDiscovered() = runBlocking {
        val store = store()

        assertEquals(emptyMap<Int, Int>(), store.pin("connection-a", mapOf(28 to null)))
        assertEquals(mapOf(28 to 55, 29 to 60), store.pin("connection-a", mapOf(28 to 55, 29 to 60)))
    }

    @Test
    fun pinsAreIsolatedPerConnectionAndProfile() = runBlocking {
        store().pin("connection-a", mapOf(28 to 54))

        assertEquals(mapOf(28 to 55), store().pin("connection-b", mapOf(28 to 55)))
        assertEquals(mapOf(28 to 56), store("kid-profile").pin("connection-a", mapOf(28 to 56)))
        assertEquals(mapOf(28 to 54), store().pin("connection-a", mapOf(28 to 57)))
    }

    @Test
    fun storedFileDoesNotContainConnectionKey() = runBlocking {
        store().pin("https://private.example|reader", mapOf(28 to 54))

        val stored = File(root, "files/kavita/legacy-issue-aliases.json")
        assertTrue(stored.exists())
        assertFalse(stored.readText().contains("private.example"))
    }
}
