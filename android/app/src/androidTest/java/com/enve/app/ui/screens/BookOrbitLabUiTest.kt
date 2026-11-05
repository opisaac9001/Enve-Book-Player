package com.enve.app.ui.screens

import android.content.Context
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileSwitchCoordinator
import com.enve.app.profiles.ProfileRuntimeRegistry
import com.enve.bookorbit.auth.BookOrbitOidcStart
import com.enve.bookorbit.auth.BookOrbitOidcCallback
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.FamilyProfileRole
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ConnectionAuthMode
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.ConnectionScope
import com.enve.engine.library.BookOrbitCollectionEdit
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BookOrbitLabUiTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test fun oidcCodeExchangeAndRefresh(): Unit = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val fixture = File(context.filesDir, "bookorbit-live-test.json")
        assumeTrue("Requires a disposable BookOrbit lab authorization", fixture.isFile)
        val config = JSONObject(fixture.readText())
        val request = File(context.filesDir, "bookorbit-sso-request.json")
        val callback = File(context.filesDir, "bookorbit-sso-callback.txt")
        request.delete()
        callback.delete()
        val runtimes = ProfileRuntimeRegistry(context)
        val id = "bookorbit-sso-${UUID.randomUUID()}"
        val component = runtimes.open(id)
        try {
            val server = config.getString("base_url")
            val flow = component.bookOrbitOidcFlow()
            val start = flow.start(server, emptyMap())
            assertTrue("BookOrbit must return a native OIDC authorization", start is BookOrbitOidcStart.Ready)
            request.writeText(JSONObject().put("authorizationUrl", (start as BookOrbitOidcStart.Ready).authUrl).toString())
            withTimeout(180_000) { while (!callback.isFile) delay(100) }
            val result = flow.completeCallback(Uri.parse(callback.readText()))
            assertTrue("BookOrbit must accept its authorization code and PKCE verifier", result is BookOrbitOidcCallback.Success)
            val identity = result as BookOrbitOidcCallback.Success
            assertTrue(identity.serverUrl == server)
            val connection = ProviderConnection(UUID.randomUUID().toString(), BookSource.BOOKORBIT,
                "SSO lab verification", server, identity.username, authMode = ConnectionAuthMode.SSO)
            component.connections().upsert(connection)
            component.preferences().setActiveConnectionId(connection.id)
            component.preferences().setActiveBookSource(BookSource.BOOKORBIT)
            component.preferences().saveServerInfo(server, identity.username)
            flow.persistTokensForConnection(connection.id, identity.username)
            assertFalse(component.vault().get(CredentialVault.refreshTokenKey(connection.id)).isNullOrBlank())
            assertNull(component.vault().get(CredentialVault.passwordKey(connection.id)))
            withContext(ConnectionScope.asContextElement(connection.id)) {
                assertTrue(component.bookOrbitRepository().validateConnection().getOrThrow())
                assertTrue(component.bookOrbitRepository().getLibraries().getOrThrow().isNotEmpty())
                component.vault().put(CredentialVault.accessTokenKey(connection.id), "stale-lab-token")
                assertTrue(component.bookOrbitRepository().validateConnection().getOrThrow())
                assertFalse(component.vault().get(CredentialVault.accessTokenKey(connection.id)) == "stale-lab-token")
            }
        } finally {
            request.delete()
            callback.delete()
            val locations = component.storageLocations()
            runtimes.close(id)
            locations.filesDirectory.deleteRecursively()
            locations.cacheDirectory.deleteRecursively()
            locations.readerDatabaseFile.parentFile?.deleteRecursively()
        }
    }

    @Test fun nonAdminLoginCollectionsAndNarratedReading() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val fixture = File(context.filesDir, "bookorbit-live-test.json")
        assumeTrue("Requires a disposable BookOrbit lab account", fixture.isFile)
        val config = JSONObject(fixture.readText())
        var stage = "profile setup"
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
                    profileId = profiles.addProfile("BookOrbit lab verification", FamilyProfileRole.ADULT).id
                    profiles.switchProfile(profileId)
                }
                compose.waitUntil(30_000) { profiles.activeRuntime.value?.profileId == profileId && !profiles.state.value.switching }
                stage = "manual connection navigation"
                compose.waitUntil(30_000) { runCatching { compose.onRoot().fetchSemanticsNode(); true }.getOrDefault(false) }
                if (compose.onAllNodesWithText("Maybe later").fetchSemanticsNodes().isNotEmpty()) {
                    compose.onNodeWithText("Maybe later").performClick()
                }
                compose.waitUntil(15_000) { compose.onAllNodesWithText("Add a source").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText("Add a source").performClick()
                stage = "manual setup"
                compose.waitUntil(10_000) { compose.onAllNodesWithText("Set up manually").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText("Set up manually").performClick()
                stage = "BookOrbit selection"
                compose.waitUntil(10_000) { compose.onAllNodesWithText("BookOrbit").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText("BookOrbit").performScrollTo().performClick()
                stage = "password login"
                compose.onNodeWithText("HTTP", useUnmergedTree = true).performClick()
                val fields = compose.onAllNodes(hasSetTextAction())
                assertEquals(3, fields.fetchSemanticsNodes().size)
                fields[0].performTextReplacement(Uri.parse(config.getString("base_url")).authority!!)
                fields[1].performTextReplacement(config.getString("username"))
                fields[2].performTextReplacement(config.getString("password"))
                androidx.test.espresso.Espresso.closeSoftKeyboard()
                compose.waitForIdle()
                compose.onNodeWithText("Connect BookOrbit").performScrollTo().assertIsEnabled()
                    .performSemanticsAction(SemanticsActions.OnClick) { it() }
                val component = profiles.activeRuntime.value!!.component
                compose.waitUntil(60_000) { component.connections().getConnectionsSync().any { it.source == BookSource.BOOKORBIT } }
                val connection = component.connections().getConnectionsSync().single { it.source == BookSource.BOOKORBIT }
                stage = "library and personal collections"
                val narrated = runBlocking {
                    withContext(ConnectionScope.asContextElement(connection.id)) {
                        val repository = component.bookOrbitRepository()
                        assertTrue(repository.validateConnection().getOrThrow())
                        assertFalse(repository.isCurrentUserAdmin().getOrThrow())
                        assertTrue(repository.getLibraries().getOrThrow().isNotEmpty())
                        assertTrue(repository.getRecentlyAdded(20).getOrThrow().isNotEmpty())
                        val book = repository.getBook(config.getString("narratedBookId"), config.getString("narratedLibraryId")).getOrThrow()
                        assertTrue(book.readAlongAvailable)
                        assertTrue(component.library().bookOrbitCollectionConnections().any { it.id == connection.id })
                        val collection = checkNotNull(component.library().createBookOrbitCollection(connection.id,
                            BookOrbitCollectionEdit(name = "Enve live UI verification", description = null, icon = "folder", syncToKobo = false)))
                        try {
                            assertTrue(collection.isEditable)
                            assertTrue(component.library().addBookToBookOrbitCollection(collection, book))
                            assertTrue(component.library().bookOrbitCollectionsForBook(book).any { it.collection.key == collection.key && it.containsBook })
                        } finally {
                            assertTrue(component.library().deleteBookOrbitCollection(collection))
                        }
                        book
                    }
                }
                stage = "return to library"
                repeat(4) {
                    if (compose.onAllNodesWithText("Library").fetchSemanticsNodes().isEmpty()) {
                        androidx.test.espresso.Espresso.pressBack()
                        compose.waitForIdle()
                    }
                }
                compose.onNodeWithText("Library").performClick()
                stage = "find narrated book"
                runBlocking { withTimeout(300_000) { component.library().allBooks.first { books -> books.any { it.title == narrated.title } } } }
                compose.onNodeWithContentDescription("Source").performClick()
                compose.onNodeWithText("BookOrbit").performClick()
                compose.onNodeWithContentDescription("Search the library").performClick()
                compose.onAllNodes(hasSetTextAction())[0].performTextReplacement(narrated.title)
                compose.waitUntil(60_000) { compose.onAllNodesWithText(narrated.title).fetchSemanticsNodes().isNotEmpty() }
                androidx.test.espresso.Espresso.closeSoftKeyboard()
                compose.onAllNodesWithText(narrated.title)[0].performClick()
                compose.waitUntil(20_000) { compose.onAllNodesWithText("Read").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText("Read").performClick()
                stage = "narrated reader"
                compose.waitUntil(60_000) { compose.onAllNodesWithContentDescription("Read Aloud").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithContentDescription("Read Aloud").performClick()
                compose.waitUntil(30_000) { component.readAloud().state.value.isPlaying }
                compose.waitUntil(15_000) { component.readAloud().state.value.positionMs > 500L }
                stage = "pause and resume"
                compose.waitUntil(10_000) { compose.onAllNodesWithContentDescription("Pause read aloud").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithContentDescription("Pause read aloud").performClick()
                compose.waitUntil(10_000) { !component.readAloud().state.value.isPlaying }
                compose.onNodeWithContentDescription("Play read aloud").performClick()
                compose.waitUntil(10_000) { component.readAloud().state.value.isPlaying }
            } catch (failure: Throwable) {
                var message = failure.message.orEmpty()
                for (key in listOf("base_url", "username", "password")) message = message.replace(config.getString(key), "<private>")
                message = message.replace(Regex("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b"), "<lab>")
                throw AssertionError("BookOrbit lab UI failed at $stage: ${failure.javaClass.simpleName}: $message")
            } finally {
                runBlocking {
                    profiles.activeRuntime.value?.component?.readAloud()?.stopActiveAndAwait()
                    profiles.switchProfile(owner.profileId)
                    profileId?.let { profiles.removeProfile(it) }
                    if (!enabled) profiles.disableProfiles()
                }
            }
        }
    }
}
