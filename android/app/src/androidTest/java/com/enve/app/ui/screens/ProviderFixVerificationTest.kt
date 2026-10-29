package com.enve.app.ui.screens

import android.graphics.Bitmap
import androidx.compose.ui.test.hasSetTextAction
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onLast
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextReplacement
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.state.ToggleableState
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.espresso.Espresso
import com.enve.app.MainActivity
import java.net.HttpURLConnection
import java.net.URI
import java.io.File
import java.io.FileOutputStream
import org.junit.Assert.assertFalse
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.rules.TestWatcher
import org.junit.runner.Description
import org.json.JSONObject

@RunWith(AndroidJUnit4::class)
class ProviderFixVerificationTest {
    @get:Rule(order = 0)
    val compose = createAndroidComposeRule<MainActivity>()

    @get:Rule(order = 1)
    val evidence = object : TestWatcher() {
        override fun failed(e: Throwable, description: Description) {
            capture("failure-${description.methodName}")
        }
    }

    @Before
    fun requireFixture() {
        assumeTrue(InstrumentationRegistry.getArguments().getString("enveProviderUi") == "1")
    }

    private fun mode(value: String, port: Int = 18780, libraryDelay: Int = 0, catalogTitle: String? = null) {
        val connection = URI("http://127.0.0.1:$port/__enve_test/mode").toURL().openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            val body = JSONObject().put("mode", value).put("libraryDelay", libraryDelay)
            if (catalogTitle != null) body.put("catalogTitle", catalogTitle)
            connection.outputStream.use { it.write(body.toString().toByteArray()) }
            check(connection.responseCode == 200)
        } finally {
            connection.disconnect()
        }
    }

    private fun fixtureState(port: Int): JSONObject =
        URI("http://127.0.0.1:$port/__enve_test/mode").toURL().openStream().use {
            JSONObject(it.bufferedReader().readText())
        }

    private fun click(text: String) {
        val later = compose.onAllNodesWithText("Maybe later")
        if (later.fetchSemanticsNodes().isNotEmpty()) {
            later.onLast().performClick()
            compose.waitForIdle()
        }
        compose.waitUntil(15_000) { compose.onAllNodesWithText(text).fetchSemanticsNodes().isNotEmpty() }
        compose.onAllNodesWithText(text).onLast().performClick()
    }

    private fun providerForm(provider: String, port: Int, password: String) {
        compose.onNodeWithContentDescription("Settings").performClick()
        click("Sources")
        click("Add a source")
        click("Set up manually")
        click(provider)
        click("HTTP")
        compose.waitUntil(10_000) { compose.onAllNodes(hasSetTextAction()).fetchSemanticsNodes().size == 3 }
        val fields = compose.onAllNodes(hasSetTextAction())
        fields[0].performTextReplacement("127.0.0.1:$port")
        fields[1].performTextReplacement("uifixture")
        fields[2].performTextReplacement(password)
        Espresso.closeSoftKeyboard()
        compose.waitForIdle()
        click("Connect $provider")
    }

    private fun kavitaForm(port: Int = 18780, password: String = "ui-wrong-password") {
        providerForm("Kavita", port, password)
    }

    private fun capture(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = checkNotNull(instrumentation.uiAutomation.takeScreenshot())
        val file = File(instrumentation.targetContext.getExternalFilesDir(null), "provider-ui-$name.png")
        FileOutputStream(file).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    @Test
    fun kavitaWrongPasswordThenSuccessfulLogin() {
        mode("healthy")
        kavitaForm()
        compose.waitUntil(20_000) {
            compose.onAllNodesWithText("Invalid username or password").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onAllNodes(hasSetTextAction())[2].performTextReplacement("ui-valid-password")
        Espresso.closeSoftKeyboard()
        compose.waitForIdle()
        click("Connect Kavita")
        compose.waitUntil(30_000) {
            compose.onAllNodesWithText("Sign in to Kavita").fetchSemanticsNodes().isEmpty()
        }
        assertFalse(compose.onAllNodesWithText("Invalid username or password").fetchSemanticsNodes().isNotEmpty())
        capture("kavita-login")
    }

    @Test
    fun kavitaServerFailureRetainsHttpStatus() {
        mode("503")
        try {
            kavitaForm(password = "ui-valid-password")
            compose.waitUntil(20_000) {
                compose.onAllNodesWithText("503", substring = true).fetchSemanticsNodes().isNotEmpty()
            }
            assertFalse(compose.onAllNodesWithText("Invalid username or password").fetchSemanticsNodes().isNotEmpty())
        } finally {
            mode("healthy")
        }
    }

    @Test
    fun kavitaConnectionRefusedHasAConnectionError() {
        kavitaForm(port = 18789)
        compose.waitUntil(20_000) {
            compose.onAllNodesWithText("connect to", substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        assertFalse(compose.onAllNodesWithText("Invalid username or password").fetchSemanticsNodes().isNotEmpty())
    }

    @Test
    fun jellyfinLiveLoginLeavesTheCredentialForm() {
        providerForm("Jellyfin", 18781, "ui-valid-password")
        compose.waitUntil(30_000) {
            compose.onAllNodesWithText("Sign in to Jellyfin").fetchSemanticsNodes().isEmpty()
        }
        assertFalse(compose.onAllNodesWithText("Invalid username or password").fetchSemanticsNodes().isNotEmpty())
        capture("jellyfin-login")
    }

    private fun jellyfinDetail() {
        click("Library")
        compose.onNodeWithContentDescription("Search the library").performClick()
        compose.onAllNodes(hasSetTextAction())[0].performTextReplacement("Chaptered M4B Book")
        Espresso.closeSoftKeyboard()
        compose.waitUntil(20_000) {
            compose.onAllNodesWithContentDescription("Chaptered M4B Book", substring = true).fetchSemanticsNodes().isNotEmpty()
        }
        compose.onNodeWithContentDescription("Chaptered M4B Book", substring = true).performClick()
    }

    @Test
    fun jellyfinDownloadCompletes() {
        jellyfinDetail()
        ensureJellyfinDownloaded()
        capture("jellyfin-download-complete")
    }

    @Test
    fun jellyfinChapterRefreshReplacesCachedMarks() {
        jellyfinDetail()
        compose.onAllNodesWithContentDescription("More").onLast().performClick()
        click("Fetch chapters")
        compose.onAllNodes(hasScrollAction()).onLast().performScrollToNode(hasText("Chapters", ignoreCase = true))
        compose.waitUntil(30_000) { compose.onAllNodesWithText("Opening").fetchSemanticsNodes().isNotEmpty() }
        compose.onAllNodes(hasScrollAction()).onLast().performScrollToNode(hasText("Opening"))
        compose.onAllNodesWithText("Opening").onLast().assertIsDisplayed()
        compose.onAllNodesWithText("Middle").onLast().assertIsDisplayed()
        compose.onAllNodesWithText("Ending").onLast().assertIsDisplayed()
        assertFalse(compose.onAllNodesWithText("All 40 chapters").fetchSemanticsNodes().isNotEmpty())
        capture("jellyfin-refreshed-chapters")
        click("Middle")
        compose.waitUntil(20_000) {
            compose.onAllNodesWithContentDescription("Pause").fetchSemanticsNodes().isNotEmpty()
        }
        compose.onAllNodesWithContentDescription("Pause").onLast().assertIsDisplayed().performClick()
        capture("jellyfin-middle-chapter-playback")
    }

    private fun setSourceEnabled(provider: String, enabled: Boolean) {
        compose.onNodeWithContentDescription("Settings").performClick()
        click("Sources")
        compose.onAllNodesWithText("$provider (", substring = true).onLast().performClick()
        val toggle = compose.onAllNodes(isToggleable()).onLast()
        val checked = toggle.fetchSemanticsNode().config[SemanticsProperties.ToggleableState] == ToggleableState.On
        if (checked != enabled) toggle.assertIsDisplayed().performClick()
        repeat(3) {
            compose.onAllNodesWithContentDescription("Back").onLast().assertIsDisplayed().performClick()
        }
    }

    private fun assertLibraryCount(count: Int) {
        compose.waitUntil(30_000) {
            runCatching {
                compose.onAllNodesWithText("$count IN YOUR LIBRARY", ignoreCase = true).onLast().assertIsDisplayed()
                true
            }.getOrDefault(false)
        }
    }

    private fun waitForRefreshComplete() {
        compose.waitUntil(45_000) {
            runCatching {
                compose.onNodeWithContentDescription("Refresh").assertIsEnabled()
                true
            }.getOrDefault(false)
        }
    }

    @Test
    fun sourceSwitchingAndRestartPhase() {
        val phase = InstrumentationRegistry.getArguments().getString("enveSourcePhase")
        assumeTrue(phase != null)
        click("Library")
        when (phase) {
            "a" -> {
                setSourceEnabled("Jellyfin", false)
                setSourceEnabled("Kavita", true)
                waitForRefreshComplete()
                assertLibraryCount(58)
            }
            "a-restart" -> {
                assertLibraryCount(58)
                setSourceEnabled("Kavita", false)
                setSourceEnabled("Jellyfin", true)
                waitForRefreshComplete()
                assertLibraryCount(124)
            }
            "b-restart" -> {
                assertLibraryCount(124)
                setSourceEnabled("Jellyfin", false)
                waitForRefreshComplete()
                assertLibraryCount(0)
            }
            "none-restart" -> {
                assertLibraryCount(0)
                setSourceEnabled("Kavita", true)
                waitForRefreshComplete()
                assertLibraryCount(58)
                val before = fixtureState(18781).getInt("catalogRequestCount")
                mode("healthy", 18781, catalogTitle = "Enve Source Enable Race")
                mode("healthy", libraryDelay = 15)
                try {
                    compose.onNodeWithContentDescription("Refresh").performClick()
                    compose.waitUntil(10_000) { fixtureState(18780).getInt("activeDelayed") > 0 }
                    setSourceEnabled("Jellyfin", true)
                    assertLibraryCount(182)
                    compose.waitUntil(45_000) { fixtureState(18781).getInt("catalogRequestCount") > before }
                    compose.onNodeWithContentDescription("Search the library").performClick()
                    compose.onAllNodes(hasSetTextAction())[0].performTextReplacement("Enve Source Enable Race")
                    Espresso.closeSoftKeyboard()
                    compose.waitUntil(30_000) {
                        compose.onAllNodesWithContentDescription("Enve Source Enable Race", substring = true).fetchSemanticsNodes().isNotEmpty()
                    }
                    capture("source-enabled-during-refresh-new-catalog-title")
                } finally {
                    mode("healthy")
                    mode("healthy", 18781)
                }
                compose.onAllNodes(hasSetTextAction())[0].performTextReplacement("Chaptered M4B Book")
                Espresso.closeSoftKeyboard()
                waitForRefreshComplete()
                compose.onNodeWithContentDescription("Refresh").performClick()
                compose.waitUntil(45_000) {
                    compose.onAllNodesWithContentDescription("Chaptered M4B Book", substring = true).fetchSemanticsNodes().isNotEmpty()
                }
                compose.onAllNodes(hasSetTextAction())[0].performTextReplacement("")
                Espresso.closeSoftKeyboard()
            }
            "both-restart" -> assertLibraryCount(182)
            else -> error("Unknown source test phase")
        }
        capture("source-$phase")
    }

    private fun jellyfinIsDownloaded(): Boolean =
        runCatching { compose.onAllNodesWithText("Downloaded").onLast().assertIsDisplayed(); true }.getOrDefault(false)

    private fun ensureJellyfinDownloaded() {
        val retry = compose.onAllNodesWithText("Try again")
        if (!jellyfinIsDownloaded()) {
            if (retry.fetchSemanticsNodes().isNotEmpty()) retry.onLast().performClick() else click("Download")
        }
        compose.waitUntil(90_000) { jellyfinIsDownloaded() }
    }

    @Test
    fun jellyfinDownloadedBookPlaysOffline() {
        mode("healthy", 18781)
        try {
            jellyfinDetail()
            ensureJellyfinDownloaded()
            mode("503", 18781)
            compose.onAllNodesWithText("Downloaded").onLast().assertIsDisplayed()
            click("Listen")
            compose.waitUntil(20_000) {
                compose.onAllNodesWithContentDescription("Pause").fetchSemanticsNodes().isNotEmpty()
            }
            val times = compose.onAllNodes(SemanticsMatcher("elapsed playback time") { node ->
                node.config.getOrNull(SemanticsProperties.Text)?.any {
                    it.text.matches(Regex("\\d+:\\d{2}"))
                } == true
            })
            val initialTime = times.onLast().fetchSemanticsNode().config[SemanticsProperties.Text].first().text
            compose.waitUntil(15_000) {
                times.onLast().fetchSemanticsNode().config[SemanticsProperties.Text].first().text != initialTime
            }
            capture("jellyfin-offline-playback")
            compose.onAllNodesWithContentDescription("Pause").onLast().assertIsDisplayed().performClick()
        } finally {
            mode("healthy", 18781)
        }
    }
}
