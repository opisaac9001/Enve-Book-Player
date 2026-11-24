package com.enve.app.ui.screens

import android.content.Context
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileSwitchCoordinator
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.FamilyProfileRole
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.engine.library.RemoteLibraryRequest
import com.enve.core.data.provider.RemoteCatalogRequest
import com.enve.core.data.model.AppMediaType
import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.flow.first
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SiloRemoteCatalogUiTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test fun serverSearchAndFilters() {
        val phase = InstrumentationRegistry.getArguments().getString("catalogPhase")
        assumeTrue("Requires the local Silo test relay", phase != null)
        val context = ApplicationProvider.getApplicationContext<Context>()
        val stateFile = File(context.filesDir, "silo-catalog-ui-state.json")
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var profiles: ProfileSwitchCoordinator
            scenario.onActivity { profiles = it.profiles }
            compose.waitUntil(30_000) { profiles.activeRuntime.value != null }
            if (phase == "setup") {
                check(!stateFile.exists()) { "Restore the previous catalog test profile first" }
                val owner = profiles.activeRuntime.value!!.profileId
                val enabled = profiles.state.value.enabled
                runBlocking {
                    if (!enabled) profiles.setupOwner(profiles.state.value.profiles.first { it.id == owner }.name, null, null)
                    val profile = profiles.addProfile("Silo Search QA", FamilyProfileRole.ADULT).id
                    stateFile.writeText(JSONObject().put("owner", owner).put("enabled", enabled).put("profile", profile).toString())
                    profiles.switchProfile(profile)
                    val component = profiles.activeRuntime.value!!.component
                    component.preferencesFacade().setReadingEnabled(true)
                    component.serverSync().setEnabled(false)
                    val id = "catalog-ui-connection"
                    component.vault().put(CredentialVault.accessTokenKey(id), "browse-fixture-token")
                    component.connections().upsert(ProviderConnection(id, BookSource.SILO, "Silo Search QA", "http://127.0.0.1:18764", "fixture"))
                    withTimeout(60_000) { component.library().refresh() }
                    val page = component.library().remoteCatalogPage(RemoteLibraryRequest(catalog = RemoteCatalogRequest(mediaType = AppMediaType.EBOOK)))
                    assertNull(page.error)
                    assertFalse(page.offline)
                    assertTrue(page.books.isNotEmpty())
                    assertTrue(page.books.size <= 100)
                    assertTrue(page.books.all { it.language != null })
                }
            } else if (phase == "cleanup") {
                val state = JSONObject(stateFile.readText())
                runBlocking {
                    profiles.activeRuntime.value!!.component.playback().stop()
                    profiles.switchProfile(state.getString("owner"))
                    profiles.removeProfile(state.getString("profile"))
                    if (!state.getBoolean("enabled")) profiles.disableProfiles()
                }
                stateFile.delete()
                return
            }
            runBlocking {
                val prefs = profiles.activeRuntime.value!!.component.preferencesFacade()
                prefs.setLibraryAdvancedFilters("")
                prefs.setLibraryStatus("ALL")
                prefs.setLibrarySelection("")
                prefs.setLibraryMedia("ALL")
            }
            if (compose.onAllNodesWithText("Maybe later").fetchSemanticsNodes().isNotEmpty()) compose.onNodeWithText("Maybe later").performClick()
            compose.waitUntil(15_000) { compose.onAllNodesWithText("Library").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Library").performClick()
            compose.waitUntil(15_000) { compose.onAllNodesWithContentDescription("Search the library").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Search the library").performClick()
            compose.onAllNodes(hasSetTextAction())[0].performTextReplacement("Alice")
            compose.waitUntil(15_000) { compose.onAllNodesWithText("Alice", substring = true).fetchSemanticsNodes().size > 1 }
            compose.onNodeWithContentDescription("Close search").performClick()
            compose.onNodeWithContentDescription("Search the library").assertExists()
            assertTrue(compose.onAllNodes(hasSetTextAction()).fetchSemanticsNodes().isEmpty())
            compose.onNodeWithContentDescription("Filter & Sort").performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithText("Ebooks").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Ebooks").performScrollTo().performClick()
            compose.waitUntil(10_000) {
                compose.onAllNodesWithContentDescription("Find a genre or language").fetchSemanticsNodes().isNotEmpty()
            }
            compose.onNodeWithContentDescription("Find a genre or language").performScrollTo().performTextReplacement("Fiction")
            compose.waitUntil(10_000) { compose.onAllNodesWithText("Fiction").fetchSemanticsNodes().size > 1 }
            compose.onNode(hasText("Fiction") and hasClickAction() and !hasSetTextAction()).performScrollTo().performClick()
            compose.onNodeWithContentDescription("Find a genre or language").performScrollTo().performTextReplacement("en")
            compose.waitUntil(10_000) { compose.onAllNodesWithText("en").fetchSemanticsNodes().size > 1 }
            compose.onNode(hasText("en") and hasClickAction() and !hasSetTextAction()).performScrollTo().performClick()
            compose.onNodeWithText("RATING · CACHED BOOKS ONLY").assertExists()
            androidx.test.espresso.Espresso.closeSoftKeyboard()
            compose.onNodeWithText("Done").performScrollTo().performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithText("50+ books").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Load more").performClick()
            compose.waitUntil(10_000) { compose.onAllNodesWithText("100+ books").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Search the library").performClick()
            compose.onAllNodes(hasSetTextAction())[0].performTextReplacement("story")
            compose.waitUntil(10_000) { compose.onAllNodesWithText("28 books").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithContentDescription("Close search").performClick()
            compose.onNodeWithContentDescription("Search the library").assertExists()
        }
    }
}
