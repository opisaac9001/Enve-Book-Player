package com.enve.app.ui.screens

import android.content.Context
import android.net.Uri
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileSwitchCoordinator
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.FamilyProfileRole
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.remote.LoginAttempt
import com.enve.core.data.remote.LoginAttemptScope
import com.enve.engine.bookorbit.BookOrbitBookDropQuery
import com.enve.engine.bookorbit.BookOrbitBookDropStatus
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class BookOrbitFeaturesUiTest {
    @get:Rule val compose = createEmptyComposeRule()

    private fun tag(value: String) = compose.onNodeWithTag(value)
    private fun waitTag(value: String) = compose.waitUntil(30_000) {
        compose.onAllNodesWithTag(value).fetchSemanticsNodes().isNotEmpty()
    }
    private fun openTool(tool: String) {
        compose.onNodeWithContentDescription("More library options").performClick()
        tag("library-bookorbit-$tool").performClick()
    }

    @Test fun liveFeatureScreens() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val fixture = File(context.filesDir, "bookorbit-features-live-test.json")
        assumeTrue("Requires isolated BookOrbit feature fixtures", fixture.isFile)
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
            val staged = mutableListOf<Int>()
            try {
                runBlocking {
                    if (!enabled) profiles.setupOwner(ownerName, null, null)
                    profileId = profiles.addProfile("BookOrbit Feature UI", FamilyProfileRole.ADULT).id
                    profiles.switchProfile(profileId)
                }
                compose.waitUntil(30_000) { profiles.activeRuntime.value?.profileId == profileId && !profiles.state.value.switching }
                stage = "lab authentication"
                val component = profiles.activeRuntime.value!!.component
                val connection = ProviderConnection(UUID.randomUUID().toString(), BookSource.BOOKORBIT,
                    "BookOrbit Feature Lab", config.getString("base_url"), config.getString("username"))
                val book = runBlocking {
                    component.serverSync().setEnabled(true)
                    val attempt = LoginAttempt(connection.serverUrl, BookSource.BOOKORBIT, emptyMap(), connection.username)
                    withContext(LoginAttemptScope.asContextElement(attempt)) {
                        component.passwordLogins().getValue(BookSource.BOOKORBIT)
                            .login(connection.serverUrl, connection.username, config.getString("password")).getOrThrow()
                    }
                    val token = checkNotNull(attempt.accessToken ?: component.preferences().getAccessTokenSync())
                    component.connections().upsert(connection)
                    component.preferences().setActiveConnectionId(connection.id)
                    component.preferences().setActiveBookSource(BookSource.BOOKORBIT)
                    component.preferences().saveServerInfo(connection.serverUrl, connection.username)
                    component.vault().put(CredentialVault.accessTokenKey(connection.id), token)
                    attempt.refreshToken?.let { component.vault().put(CredentialVault.refreshTokenKey(connection.id), it) }
                    component.vault().put(CredentialVault.passwordKey(connection.id), config.getString("password"))
                    withContext(ConnectionScope.asContextElement(connection.id)) {
                        component.bookOrbitRepository().getBook(config.getJSONArray("books").getInt(1).toString(), config.getInt("library_id").toString())
                            .getOrThrow().copy(connectionId = connection.id).also { component.bookCacheDao().upsert(listOf(it.toCachedBook())) }
                    }
                }
                stage = "library navigation"
                compose.waitUntil(30_000) { runCatching { compose.onRoot().fetchSemanticsNode(); true }.getOrDefault(false) }
                if (compose.onAllNodesWithText("Maybe later").fetchSemanticsNodes().isNotEmpty()) compose.onNodeWithText("Maybe later").performClick()
                compose.onNodeWithText("Library").performClick()
                stage = "smart scope search and detail"
                openTool("smart-scopes")
                val scope = config.getJSONArray("scope_ids").getInt(0)
                waitTag("bookorbit-scope-$scope")
                tag("bookorbit-scope-$scope").performClick()
                tag("bookorbit-scopes-search").performTextReplacement("Enve Feature Lab Android")
                waitTag("bookorbit-scope-book-${book.id}")
                androidx.test.espresso.Espresso.closeSoftKeyboard()
                tag("bookorbit-scope-book-${book.id}").performClick()
                waitTag("detail-rating-3")
                if (context.resources.configuration.screenWidthDp >= 840) {
                    compose.onAllNodesWithTag("hearth-list-pane").onLast().assertIsDisplayed()
                    compose.onAllNodesWithTag("hearth-detail-pane").onLast().assertIsDisplayed()
                }
                stage = "pending rating and status controls"
                val chosenStatus = if (book.serverReadStatus?.uppercase() == "WANT_TO_READ") "ON_HOLD" else "WANT_TO_READ"
                runBlocking { component.connections().upsert(connection.copy(enabled = false)) }
                tag("detail-rating-3").performScrollTo().performClick()
                tag("detail-read-status-$chosenStatus").performScrollTo().performClick()
                compose.waitUntil(10_000) { component.pendingBookMutations().pending.value.size == 2 }
                tag("detail-read-status-sync").assertExists()
                runBlocking { component.connections().upsert(connection) }
                tag("detail-read-status-retry").performScrollTo().performClick()
                tag("detail-rating-retry").performScrollTo().performClick()
                compose.waitUntil(30_000) { component.pendingBookMutations().pending.value.isEmpty() }
                runBlocking { withContext(ConnectionScope.asContextElement(connection.id)) {
                    val remote = component.bookOrbitRepository().getBook(book.id, book.libraryId).getOrThrow()
                    assertEquals(3f, remote.personalRating)
                    assertEquals(chosenStatus, remote.serverReadStatus?.uppercase())
                } }
                androidx.test.espresso.Espresso.pressBack()
                waitTag("bookorbit-scopes-search")
                tag("bookorbit-scopes-search").assertTextContains("Enve Feature Lab Android")
                tag("bookorbit-scopes-search").performTextClearance()
                tag("bookorbit-scope-${config.getJSONArray("scope_ids").getInt(1)}").performClick()
                compose.waitUntil(20_000) { compose.onAllNodesWithText("This scope is empty").fetchSemanticsNodes().isNotEmpty() }
                androidx.test.espresso.Espresso.closeSoftKeyboard()
                androidx.test.espresso.Espresso.pressBack()
                stage = "notes-only highlights"
                openTool("highlights")
                waitTag("bookorbit-highlights-notes-only")
                tag("bookorbit-highlights-notes-only").performClick()
                tag("bookorbit-highlights-notes-only").assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.StateDescription, "Selected"))
                waitTag("bookorbit-highlights-list")
                androidx.test.espresso.Espresso.pressBack()
                stage = "Book Drop review and approval"
                val upload = runBlocking {
                    component.bookOrbit().importBookDropFile(connection.id,
                        Uri.fromFile(File(context.filesDir, "bookorbit-features-approve.epub")).toString()).also { staged += it.id }
                }
                runBlocking { withTimeout(45_000) {
                    while (component.bookOrbit().bookDropItems(connection.id, BookOrbitBookDropQuery()).items.none { it.id == upload.id && it.status == BookOrbitBookDropStatus.READY }) delay(500)
                } }
                openTool("book-drop")
                waitTag("bookorbit-bookdrop-item-${upload.id}")
                tag("bookorbit-bookdrop-item-${upload.id}").performClick()
                waitTag("bookorbit-bookdrop-field-title")
                val title = "Enve Android UI ${UUID.randomUUID().toString().take(8)}"
                tag("bookorbit-bookdrop-field-title").performScrollTo().performTextReplacement(title)
                androidx.test.espresso.Espresso.closeSoftKeyboard()
                tag("bookorbit-bookdrop-library").performScrollTo().performClick()
                tag("bookorbit-bookdrop-library-${config.getInt("library_id")}").performClick()
                tag("bookorbit-bookdrop-save").performScrollTo().performClick()
                compose.waitUntil(20_000) { runBlocking { component.bookOrbit().bookDropItems(connection.id, BookOrbitBookDropQuery()).items.any { it.id == upload.id && it.metadata.title == title } } }
                tag("bookorbit-bookdrop-approve").performScrollTo().performClick()
                waitTag("bookorbit-bookdrop-approval")
                compose.onNodeWithText("Added to the library").assertExists()
                staged.remove(upload.id)
                tag("bookorbit-bookdrop-approval-done").performClick()
                stage = "Book Drop discard confirmation"
                val discard = runBlocking { component.bookOrbit().importBookDropFile(connection.id,
                    Uri.fromFile(File(context.filesDir, "bookorbit-features-reject.epub")).toString()).also { staged += it.id } }
                tag("bookorbit-bookdrop-refresh").performClick()
                waitTag("bookorbit-bookdrop-item-${discard.id}")
                tag("bookorbit-bookdrop-item-${discard.id}").performClick()
                tag("bookorbit-bookdrop-discard").performScrollTo().performClick()
                tag("bookorbit-bookdrop-discard-confirm").assertIsDisplayed().performClick()
                compose.waitUntil(20_000) { runBlocking { component.bookOrbit().bookDropItems(connection.id, BookOrbitBookDropQuery()).items.none { it.id == discard.id } } }
                staged.clear()
            } catch (failure: Throwable) {
                var message = failure.message.orEmpty()
                for (key in listOf("base_url", "username", "password")) message = message.replace(config.getString(key), "<private>")
                message = message.replace(Regex("\\b(?:\\d{1,3}\\.){3}\\d{1,3}\\b"), "<lab>")
                throw AssertionError("BookOrbit feature UI failed at $stage: ${failure.javaClass.simpleName}: $message")
            } finally {
                runBlocking {
                    val component = profiles.activeRuntime.value?.component
                    val connection = component?.connections()?.getConnectionsSync()?.singleOrNull { it.source == BookSource.BOOKORBIT }
                    if (connection != null && staged.isNotEmpty()) runCatching { component.bookOrbit().discardBookDropItems(connection.id, staged) }
                    profiles.switchProfile(owner.profileId)
                    profileId?.let { profiles.removeProfile(it) }
                    if (!enabled) profiles.disableProfiles()
                }
            }
        }
    }
}
