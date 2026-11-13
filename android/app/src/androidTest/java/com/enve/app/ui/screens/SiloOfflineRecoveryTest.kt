package com.enve.app.ui.screens

import android.content.Context
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileSwitchCoordinator
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.FamilyProfileRole
import com.enve.core.data.local.toBook
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.ConnectionScope
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SiloOfflineRecoveryTest {
    @Test fun recoverAcrossProcessDeath() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val fixture = File(context.filesDir, "silo-live-test.json")
        assumeTrue("Requires isolated live Silo fixtures", fixture.isFile)
        val phase = InstrumentationRegistry.getArguments().getString("silo_phase")
        assumeTrue("Run prepare, offline and replay as separate processes", phase != null)
        val config = JSONObject(fixture.readText())
        val stateFile = File(context.filesDir, "silo-recovery-state.json")
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var profiles: ProfileSwitchCoordinator
            scenario.onActivity { profiles = it.profiles }
            withTimeout(30_000) { profiles.activeRuntime.first { it != null } }
            if (phase == "prepare") {
                assertFalse("A previous recovery fixture needs cleanup", stateFile.exists())
                val owner = profiles.activeRuntime.value!!.profileId
                val enabled = profiles.state.value.enabled
                val ownerName = profiles.state.value.profiles.first { it.id == owner }.name
                if (!enabled) profiles.setupOwner(ownerName, null, null)
                val profile = profiles.addProfile("Silo offline verification", FamilyProfileRole.ADULT)
                val state = JSONObject().put("owner", owner).put("enabled", enabled).put("profile", profile.id)
                stateFile.writeText(state.toString())
                profiles.switchProfile(profile.id)
                val component = profiles.activeRuntime.value!!.component
                val connectionId = UUID.randomUUID().toString()
                state.put("connection", connectionId)
                stateFile.writeText(state.toString())
                val base = config.getString("base_url")
                val body = JSONObject().put("username", config.getString("username")).put("password", config.getString("password"))
                val tokens = withContext(Dispatchers.IO) {
                    OkHttpClient().newCall(Request.Builder().url("$base/api/v2/auth/login")
                        .post(body.toString().toRequestBody("application/json".toMediaType())).build()).execute().use {
                        assertEquals(200, it.code)
                        JSONObject(checkNotNull(it.body).string())
                    }
                }
                component.vault().put(CredentialVault.accessTokenKey(connectionId), tokens.getString("access_token"))
                component.vault().put(CredentialVault.refreshTokenKey(connectionId), tokens.getString("refresh_token"))
                component.connections().upsert(ProviderConnection(connectionId, BookSource.SILO, "Silo recovery", base, config.getString("username")))
                component.serverSync().setEnabled(true)
                component.library().refresh()
                val title = config.optString("download_title", "Delta Verification Audio")
                val audio = withTimeout(60_000) { component.library().allBooks.first { books -> books.any { it.title == title } } }
                    .single { it.title == title }
                state.put("book", audio.uniqueKey)
                component.library().download(audio)
                if (config.optBoolean("background_download")) {
                    waitUntil { (component.downloads().progressByBookId.value[audio.id]?.downloadedBytes ?: 0) > 262_144 }
                    assertFalse(component.downloads().isDownloaded(audio.id))
                    component.downloads().pauseAllAndAwait()
                    assertFalse(component.downloads().isDownloaded(audio.id))
                    InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("input keyevent KEYCODE_HOME").close()
                    val refresh = component.vault().get(CredentialVault.refreshTokenKey(connectionId))
                    component.vault().put(CredentialVault.accessTokenKey(connectionId), "expired-download-verification-token")
                    component.downloads().resumeDownloads()
                    withTimeout(180_000) { while (!component.downloads().isDownloaded(audio.id)) delay(200) }
                    assertNotEquals(refresh, component.vault().get(CredentialVault.refreshTokenKey(connectionId)))
                    assertNotEquals("expired-download-verification-token", component.vault().get(CredentialVault.accessTokenKey(connectionId)))
                } else {
                    waitUntil { component.downloads().isDownloaded(audio.id) }
                }
                val localTracks = component.downloads().localTracks(audio.id).orEmpty()
                assertTrue(localTracks.isNotEmpty())
                if (config.has("audio_sha256")) {
                    val localFile = File(java.net.URI(localTracks.single().uri))
                    val hash = java.security.MessageDigest.getInstance("SHA-256").digest(localFile.readBytes())
                        .joinToString("") { "%02x".format(it) }
                    assertEquals(config.getString("audio_sha256"), hash)
                }
                val connection = component.connections().getConnectionsSync().single { it.id == connectionId }
                component.connections().upsert(connection.copy(serverUrl = "http://127.0.0.1:9"))
                stateFile.writeText(state.toString())
            } else {
                assertTrue(stateFile.exists())
                val state = JSONObject(stateFile.readText())
                assertEquals(state.getString("profile"), profiles.activeRuntime.value!!.profileId)
                val component = profiles.activeRuntime.value!!.component
                if (phase == "cleanup") {
                    restore(profiles, state)
                    stateFile.delete()
                    return@use
                }
                val audio = checkNotNull(component.bookCacheDao().getByCacheKey(state.getString("book"))).toBook()
                assertTrue(component.downloads().isDownloaded(audio.id))
                assertTrue(component.serverSync().isEnabled)
                val pending = component.database().pendingProgressPushDao()
                if (phase == "offline") {
                    assertEquals("http://127.0.0.1:9", component.connections().getConnectionsSync().single().serverUrl)
                    val playback = component.playback()
                    val watch = launch(Dispatchers.Default) { playback.transport.collect {} }
                    try {
                        playback.open(audio.copy(isDownloaded = true), 32_000)
                        waitUntil { playback.transport.value.isPlaying && playback.transport.value.positionMs >= 32_000 }
                        playback.seekTo(45_000)
                        waitUntil { playback.transport.value.positionMs >= 45_000 }
                        playback.stop()
                        waitUntil { pending.getAll().any { it.bookId == audio.id } }
                        val queued = pending.getAll().single { it.bookId == audio.id }
                        state.put("queued_at", queued.createdAt)
                        stateFile.writeText(state.toString())
                        assertEquals(0, component.pendingProgressReplay().replay())
                        assertNotNull(pending.get(audio.id, audio.source.name, audio.connectionId.orEmpty()))
                    } finally { watch.cancelAndJoin() }
                } else if (phase == "replay") {
                    val queued = checkNotNull(pending.get(audio.id, audio.source.name, audio.connectionId.orEmpty()))
                    assertEquals(state.getLong("queued_at"), queued.createdAt)
                    val connection = component.connections().getConnectionsSync().single()
                    component.connections().upsert(connection.copy(serverUrl = config.getString("base_url")))
                    component.pendingProgressReplay().replay()
                    waitUntil { pending.getAll().none { it.bookId == audio.id } }
                    val remote = withContext(ConnectionScope.asContextElement(connection.id)) {
                        component.siloRepository().fetchAudiobookProgress(audio).getOrThrow()
                    }
                    assertTrue(checkNotNull(remote?.positionMs) in 45_000L..50_000L)
                    assertEquals(0, component.pendingProgressReplay().replay())
                    restore(profiles, state)
                    stateFile.delete()
                } else error("Unknown recovery phase")
            }
        }
        Unit
    }

    private suspend fun waitUntil(predicate: suspend () -> Boolean) = withTimeout(60_000) {
        while (!predicate()) delay(100)
    }

    private suspend fun restore(profiles: ProfileSwitchCoordinator, state: JSONObject) {
        profiles.activeRuntime.value!!.component.playback().stop()
        profiles.switchProfile(state.getString("owner"))
        profiles.removeProfile(state.getString("profile"))
        if (!state.getBoolean("enabled")) profiles.disableProfiles()
    }
}
