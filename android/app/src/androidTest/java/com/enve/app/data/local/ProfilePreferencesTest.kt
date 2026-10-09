package com.enve.app.data.local

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.hearth.HearthPreferencesStore
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.ProfilePreferences
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.engine.theme.HearthThemeMode
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class ProfilePreferencesTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Test
    fun ownerReusesExistingDataStores() {
        val first = ProfilePreferences.owner(context)
        val second = ProfilePreferences.owner(context)
        assertSame(first.enve, second.enve)
        assertSame(first.hearth, second.hearth)
    }

    @Test
    fun connectionsAndSettingsRemainBoundToTheirOriginalProfile() = runBlocking {
        val root = File(context.cacheDir, "profile-preferences-test-${UUID.randomUUID()}")
        val job = SupervisorJob()
        try {
            val scope = CoroutineScope(job + Dispatchers.IO)
            val first = ProfilePreferences.open(context, locations(root, "first"), scope)
            val second = ProfilePreferences.open(context, locations(root, "second"), scope)
            val firstConnections = ConnectionRegistry(first.enve)
            val secondConnections = ConnectionRegistry(second.enve)
            val firstTheme = HearthPreferencesStore(first.hearth)
            val secondTheme = HearthPreferencesStore(second.hearth)
            val originalFlow = firstConnections.connections
            val connection = ProviderConnection(
                id = "same-connection", source = BookSource.LOCAL,
                name = "First", serverUrl = "", username = "",
            )

            firstConnections.upsert(connection)
            firstTheme.setThemeMode(HearthThemeMode.INK)
            assertEquals(emptyList<ProviderConnection>(), secondConnections.connections.first())
            assertEquals(HearthThemeMode.SYSTEM, secondTheme.themeMode.first())
            secondConnections.upsert(connection.copy(name = "Second"))
            secondTheme.setThemeMode(HearthThemeMode.PAPER)
            firstConnections.setEnabled(connection.id, false)

            assertEquals(listOf(connection.copy(enabled = false)), originalFlow.first())
            assertEquals(listOf(connection.copy(name = "Second")), secondConnections.connections.first())
            assertEquals(HearthThemeMode.INK, firstTheme.themeMode.first())
            assertEquals(HearthThemeMode.PAPER, secondTheme.themeMode.first())
        } finally {
            job.cancelAndJoin()
            root.deleteRecursively()
        }
    }

    @Test
    fun preferencesSurviveResourceRecreation() = runBlocking {
        val root = File(context.cacheDir, "profile-preferences-test-${UUID.randomUUID()}")
        val locations = locations(root, "reader")
        val firstJob = SupervisorJob()
        val secondJob = SupervisorJob()
        try {
            val first = ProfilePreferences.open(context, locations, CoroutineScope(firstJob + Dispatchers.IO))
            HearthPreferencesStore(first.hearth).setLibraryColumns(4)
            firstJob.cancelAndJoin()

            val restored = ProfilePreferences.open(context, locations, CoroutineScope(secondJob + Dispatchers.IO))
            assertEquals(4, HearthPreferencesStore(restored.hearth).libraryColumns.first())
        } finally {
            firstJob.cancelAndJoin()
            secondJob.cancelAndJoin()
            root.deleteRecursively()
        }
    }

    private fun locations(root: File, profileId: String) = ProfileStorageLocations.forProfile(
        profileId = profileId,
        filesDirectory = File(root, "files"),
        cacheDirectory = File(root, "cache"),
        databaseDirectory = File(root, "databases"),
    )
}
