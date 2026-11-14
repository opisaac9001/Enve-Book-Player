package com.enve.app.ui.screens

import android.content.Context
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.MainActivity
import com.enve.core.auth.CredentialVault
import com.enve.app.profiles.ProfileSwitchCoordinator
import com.enve.core.data.local.FamilyProfileRole
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.provider.catalogImportConnectionKey
import java.io.File
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import org.json.JSONObject
import okhttp3.OkHttpClient
import okhttp3.Request
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SiloConnectionLabUiTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test fun freshLoginLoadsLibrariesAndBooks() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val fixture = File(context.filesDir, "silo-live-test.json")
        assumeTrue("Requires an Enve Silo lab connection", fixture.isFile)
        val config = JSONObject(fixture.readText())
        var stage = "profile setup"
        val observationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val playbackFailure = AtomicReference<String?>(null)
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var profiles: ProfileSwitchCoordinator
            scenario.onActivity { profiles = it.profiles }
            compose.waitUntil(30_000) { profiles.activeRuntime.value != null }
            val owner = profiles.activeRuntime.value!!
            val enabled = profiles.state.value.enabled
            val ownerName = profiles.state.value.profiles.first { it.id == owner.profileId }.name
            var profileId: String? = null
            try {
                runBlocking {
                    if (!enabled) profiles.setupOwner(ownerName, null, null)
                    profileId = profiles.addProfile("Silo connection verification", FamilyProfileRole.ADULT).id
                    profiles.switchProfile(profileId)
                }
                compose.waitUntil(30_000) { profiles.activeRuntime.value?.profileId == profileId && !profiles.state.value.switching }
                compose.waitUntil(30_000) { runCatching { compose.onRoot().fetchSemanticsNode(); true }.getOrDefault(false) }
                if (compose.onAllNodesWithText("Maybe later").fetchSemanticsNodes().isNotEmpty()) {
                    compose.onNodeWithText("Maybe later").performClick()
                }
                stage = "manual setup"
                compose.onNodeWithText("Add a source").performClick()
                compose.waitUntil(10_000) { compose.onAllNodesWithText("Set up manually").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText("Set up manually").performClick()
                compose.waitUntil(10_000) { compose.onAllNodesWithText("Silo").fetchSemanticsNodes().isNotEmpty() }
                compose.onAllNodesWithText("Silo")[0].performScrollTo().performClick()
                stage = "password login"
                compose.waitUntil(10_000) { compose.onAllNodesWithText("HTTP", useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText("HTTP", useUnmergedTree = true).performClick()
                val fields = compose.onAllNodes(hasSetTextAction())
                assertEquals(3, fields.fetchSemanticsNodes().size)
                fields[0].performTextReplacement(Uri.parse(config.getString("base_url")).authority!!)
                fields[1].performTextReplacement(config.getString("username"))
                fields[2].performTextReplacement(config.getString("password"))
                androidx.test.espresso.Espresso.closeSoftKeyboard()
                compose.onNodeWithText("Connect Silo").performScrollTo().performClick()
                stage = "Silo profile selection"
                compose.waitUntil(30_000) { compose.onAllNodesWithText("Silo profile").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText(config.optString("profile_name", "V2 Verification")).performClick()
                val pin = config.optString("profile_pin")
                if (pin.isNotBlank()) compose.onNodeWithText("Silo profile PIN").performTextInput(pin)
                compose.onNodeWithText(if (pin.isNotBlank()) "Unlock" else "Continue").performClick()
                val component = profiles.activeRuntime.value!!.component
                compose.waitUntil(60_000) { component.connections().getConnectionsSync().any { it.source == BookSource.SILO } }
                val connection = component.connections().getConnectionsSync().single { it.source == BookSource.SILO }
                stage = "catalog loading"
                val books = runBlocking {
                    withTimeout(300_000) {
                        component.library().allBooks.first { books ->
                            books.count { it.connectionId == connection.id } >= config.optInt("minimumBookCount", 1)
                        }
                    }
                }
                assertTrue(books.any { it.source == BookSource.SILO && it.title.isNotBlank() })
                assertTrue(runBlocking { component.library().libraries.first() }.any { it.connectionId == connection.id })
                val issues = runBlocking { component.library().importIssues.first() }.filter {
                    it.connectionKey == catalogImportConnectionKey(connection.id)
                }
                assertTrue("Catalog diagnostics: ${issues.map { it.report }}", issues.isEmpty())
                stage = "library screen"
                repeat(4) {
                    if (compose.onAllNodesWithText("Library").fetchSemanticsNodes().isEmpty()) {
                        androidx.test.espresso.Espresso.pressBack()
                        compose.waitForIdle()
                    }
                }
                compose.onNodeWithText("Library").performClick()
                compose.waitUntil(30_000) {
                    compose.onAllNodes(SemanticsMatcher("nonempty book count") { node ->
                        node.config.getOrNull(SemanticsProperties.Text).orEmpty().any {
                            it.text.matches(Regex("^[1-9][0-9,]* books$"))
                        }
                    }).fetchSemanticsNodes().isNotEmpty()
                }
                stage = "streaming player"
                val audio = books.single { it.title == config.optString("audio_title", "Delta Verification Audio") }
                assertFalse(component.serverSync().isEnabled)
                val originalRemotePosition = runBlocking {
                    withContext(ConnectionScope.asContextElement(connection.id)) {
                        component.siloRepository().fetchAudiobookProgress(audio).getOrThrow()?.positionMs
                    }
                }
                compose.onNodeWithContentDescription("Search the library").performClick()
                compose.onAllNodes(hasSetTextAction())[0].performTextReplacement(audio.title)
                androidx.test.espresso.Espresso.closeSoftKeyboard()
                compose.waitUntil(20_000) { compose.onAllNodesWithText(audio.title).fetchSemanticsNodes().isNotEmpty() }
                compose.onAllNodesWithText(audio.title)[0].performClick()
                compose.waitUntil(20_000) { compose.onAllNodesWithText("Listen").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText("Listen").performClick()
                val playback = component.playback()
                observationScope.launch { playback.transport.collect {} }
                observationScope.launch { playback.errors.collect { playbackFailure.set(it) } }
                compose.waitUntil(30_000) { playback.transport.value.isPlaying && playback.transport.value.positionMs > 500 }
                stage = "renewal during playback"
                val oldRefresh = component.vault().get(CredentialVault.refreshTokenKey(connection.id))
                component.vault().put(CredentialVault.accessTokenKey(connection.id), "expired-verification-token")
                runBlocking {
                    withContext(ConnectionScope.asContextElement(connection.id)) {
                        component.siloRepository().getLibraries().getOrThrow()
                    }
                }
                assertNotEquals("expired-verification-token", component.vault().get(CredentialVault.accessTokenKey(connection.id)))
                assertNotEquals(oldRefresh, component.vault().get(CredentialVault.refreshTokenKey(connection.id)))
                assertTrue(playback.transport.value.isPlaying)
                stage = "streaming player"
                if (audio.title == "Echo Multipart Verification") {
                    playback.seekTo(58_000)
                    compose.waitUntil(15_000) { playback.transport.value.isPlaying && playback.transport.value.positionMs > 62_000 }
                }
                playback.seekTo(40_000)
                compose.waitUntil(10_000) { playback.transport.value.positionMs >= 40_000 }
                playback.togglePlayPause()
                compose.waitUntil(10_000) { !playback.transport.value.isPlaying }
                playback.togglePlayPause()
                compose.waitUntil(10_000) { playback.transport.value.isPlaying }
                runBlocking { playback.stop() }
                val retainedRemotePosition = runBlocking {
                    withContext(ConnectionScope.asContextElement(connection.id)) {
                        component.siloRepository().fetchAudiobookProgress(audio).getOrThrow()?.positionMs
                    }
                }
                assertEquals(originalRemotePosition, retainedRemotePosition)
                stage = "playback with server sync enabled"
                runBlocking { component.serverSync().setEnabled(true) }
                val syncedPosition = if ((originalRemotePosition ?: 0L) < 45_000) 60_000L else 30_000L
                playback.open(audio, syncedPosition)
                compose.waitUntil(30_000) { playback.transport.value.isPlaying && playback.transport.value.positionMs >= syncedPosition }
                runBlocking { playback.stop() }
                var savedRemotePosition: Long? = null
                compose.waitUntil(15_000) {
                    savedRemotePosition = runBlocking {
                        withContext(ConnectionScope.asContextElement(connection.id)) {
                            component.siloRepository().fetchAudiobookProgress(audio).getOrThrow()?.positionMs
                        }
                    }
                    savedRemotePosition?.let { it in syncedPosition..(syncedPosition + 5_000) } == true
                }
                assertNotEquals(originalRemotePosition, savedRemotePosition)
                runBlocking { component.serverSync().setEnabled(false) }
                stage = "server session cleanup after sync toggle"
                val sessionClient = OkHttpClient()
                val sessionRequest = Request.Builder().url(config.getString("base_url") + "/api/v2/profiles/household/sessions")
                    .header("Authorization", "Bearer " + checkNotNull(component.vault().get(CredentialVault.accessTokenKey(connection.id))))
                    .header("X-Profile-Id", config.optString("household_profile_id").ifBlank {
                        checkNotNull(component.vault().get("silo_profile_id_${connection.id}"))
                    }).build()
                compose.waitUntil(15_000) {
                    sessionClient.newCall(sessionRequest).execute().use {
                        it.isSuccessful && JSONObject(checkNotNull(it.body).string()).getJSONArray("items").length() == 0
                    }
                }
                stage = "offline download"
                runBlocking { component.library().download(audio) }
                compose.waitUntil(60_000) { component.downloads().isDownloaded(audio.id) }
                assertTrue(component.downloads().localTracks(audio.id).orEmpty().all { it.uri.startsWith("file:") })
                stage = "offline playback"
                runBlocking { component.connections().upsert(connection.copy(serverUrl = "http://127.0.0.1:9")) }
                try {
                    playback.open(audio.copy(isDownloaded = true), 10_000)
                    compose.waitUntil(30_000) { playback.transport.value.isPlaying && playback.transport.value.positionMs > 10_500 }
                    playback.seekTo(50_000)
                    compose.waitUntil(10_000) { playback.transport.value.positionMs >= 50_000 }
                    runBlocking { playback.stop() }
                } finally {
                    runBlocking { component.connections().upsert(connection) }
                }
            } catch (failure: Throwable) {
                var message = failure.message.orEmpty() + playbackFailure.get()?.let { "; playback: $it" }.orEmpty()
                for (key in listOf("base_url", "username", "password")) message = message.replace(config.getString(key), "<private>")
                message = message.replace(Regex("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b"), "<lab>")
                throw AssertionError("Silo lab UI failed at $stage: ${failure.javaClass.simpleName}: $message")
            } finally {
                observationScope.cancel()
                runBlocking {
                    profiles.activeRuntime.value?.component?.playback()?.stop()
                    profiles.switchProfile(owner.profileId)
                    profileId?.let { profiles.removeProfile(it) }
                    if (!enabled) profiles.disableProfiles()
                }
            }
        }
    }
}
