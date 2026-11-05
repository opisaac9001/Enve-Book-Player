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
import com.enve.app.profiles.ProfileSwitchCoordinator
import com.enve.core.data.local.FamilyProfileRole
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.catalogImportConnectionKey
import java.io.File
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GrimmoryConnectionLabUiTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test fun freshLoginLoadsLibrariesAndBooks() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val fixture = File(context.filesDir, "grimmory-live-test.json")
        assumeTrue("Requires an Enve Grimmory lab connection", fixture.isFile)
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
                    profileId = profiles.addProfile("Grimmory connection verification", FamilyProfileRole.ADULT).id
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
                compose.waitUntil(10_000) { compose.onAllNodesWithText("Grimmory").fetchSemanticsNodes().isNotEmpty() }
                compose.onAllNodesWithText("Grimmory")[0].performScrollTo().performClick()
                stage = "password login"
                compose.waitUntil(10_000) { compose.onAllNodesWithText("HTTP", useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText("HTTP", useUnmergedTree = true).performClick()
                val fields = compose.onAllNodes(hasSetTextAction())
                assertEquals(3, fields.fetchSemanticsNodes().size)
                fields[0].performTextReplacement(Uri.parse(config.getString("base_url")).authority!!)
                fields[1].performTextReplacement(config.getString("username"))
                fields[2].performTextReplacement(config.getString("password"))
                androidx.test.espresso.Espresso.closeSoftKeyboard()
                compose.onNodeWithText("Connect Grimmory").performScrollTo().performClick()
                val component = profiles.activeRuntime.value!!.component
                compose.waitUntil(60_000) { component.connections().getConnectionsSync().any { it.source == BookSource.GRIMMORY } }
                val connection = component.connections().getConnectionsSync().single { it.source == BookSource.GRIMMORY }
                stage = "catalog loading"
                val books = runBlocking {
                    withTimeout(300_000) {
                        component.library().allBooks.first { books ->
                            books.count { it.connectionId == connection.id } >= config.optInt("minimumBookCount", 1)
                        }
                    }
                }
                assertTrue(books.any { it.source == BookSource.GRIMMORY && it.title.isNotBlank() })
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
            } catch (failure: Throwable) {
                var message = failure.message.orEmpty()
                for (key in listOf("base_url", "username", "password")) message = message.replace(config.getString(key), "<private>")
                message = message.replace(Regex("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b"), "<lab>")
                throw AssertionError("Grimmory lab UI failed at $stage: ${failure.javaClass.simpleName}: $message")
            } finally {
                runBlocking {
                    profiles.switchProfile(owner.profileId)
                    profileId?.let { profiles.removeProfile(it) }
                    if (!enabled) profiles.disableProfiles()
                }
            }
        }
    }
}
