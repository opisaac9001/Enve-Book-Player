package com.enve.app.ui.screens

import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.os.ParcelFileDescriptor
import android.provider.Settings
import androidx.compose.ui.test.assertHeightIsAtLeast
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertWidthIsAtLeast
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.Espresso.pressBack
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.MainActivity
import com.enve.app.profiles.ActiveProfileRuntime
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.core.data.model.BookSource
import com.enve.engine.eink.EinkMode
import com.enve.engine.prefs.HearthStartTab
import com.enve.engine.theme.HearthThemeMode
import com.enve.hearth.library.HearthLibraryViewModel
import com.enve.hearth.library.MediaFilter
import com.enve.hearth.library.StatusFilter
import dagger.hilt.android.EntryPointAccessors
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryControlsParityTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private suspend fun runtime(): ActiveProfileRuntime {
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use {
            withTimeout(20_000) { while (coordinator.activeRuntime.value == null) delay(100) }
        }
        return checkNotNull(coordinator.activeRuntime.value)
    }

    @Test
    fun removingTheLastSortStaysRemovedAfterReopeningTheLibrary(): Unit = runBlocking {
        val prefs = runtime().component.preferencesFacade()
        val originalSort = prefs.librarySortStack.first()
        val originalTab = prefs.preferredStartTab.first()
        try {
            prefs.setLibrarySortStack("RECENT:DESCENDING")
            prefs.setPreferredStartTab(HearthStartTab.LIBRARY)
            ActivityScenario.launch(MainActivity::class.java).use {
                filter().performClick()
                compose.onNodeWithContentDescription("Remove Recent sort").assertIsEnabled().performClick()
                assertDefaultOrder()
                compose.onNodeWithText("Done").performClick()
                withTimeout(5_000) { prefs.librarySortStack.first { it == "[]" } }
            }
            ActivityScenario.launch(MainActivity::class.java).use {
                filter().performClick()
                assertDefaultOrder()
                compose.onNodeWithText("+ Title").performClick()
                compose.onNodeWithContentDescription("Remove Title sort").assertIsEnabled().performClick()
                withTimeout(5_000) { prefs.librarySortStack.first { it == "[]" } }
                assertDefaultOrder()
            }
        } finally {
            prefs.setLibrarySortStack(originalSort)
            prefs.setPreferredStartTab(originalTab)
        }
    }

    @Test
    fun resettingContentFiltersPreservesSourceAndLibraryScope(): Unit = runBlocking {
        val component = runtime().component
        val prefs = component.preferencesFacade()
        val originalSort = prefs.librarySortStack.first()
        val originalFilters = prefs.libraryAdvancedFilters.first()
        val store = ViewModelStore()
        try {
            withContext(Dispatchers.Main) {
                val vm = HearthLibraryViewModel(component.library(), component.savedBooks(), component.playback(), prefs, component.connections())
                store.put("library", vm)
                vm.setSourceFilter(BookSource.GRIMMORY)
                vm.setLibraryFilter("fixture::library")
                vm.setStatus(StatusFilter.CURRENTLY_READING)
                vm.setMedia(MediaFilter.EBOOKS)
                vm.toggleGenre("Fantasy")
                vm.resetFiltersAndSorting()
                assertEquals(BookSource.GRIMMORY, vm.sourceFilter.value)
                assertEquals("fixture::library", vm.libraryFilter.value)
                assertEquals(StatusFilter.ALL, vm.status.value)
                assertEquals(MediaFilter.ALL, vm.media.value)
                assertTrue(!vm.advancedFilters.value.isActive)
            }
            withTimeout(5_000) { prefs.librarySortStack.first { it == "[]" } }
        } finally {
            withContext(Dispatchers.Main) { store.clear() }
            prefs.setLibrarySortStack(originalSort)
            prefs.setLibraryAdvancedFilters(originalFilters)
        }
    }

    @Test
    fun libraryMenusRemainReachableInPaperLargeTextLandscapeAndEink(): Unit = runBlocking {
        val component = runtime().component
        val prefs = component.preferencesFacade()
        val eink = component.einkFacade()
        val originalTheme = prefs.themeMode.first()
        val originalOled = prefs.oledEnabled.first()
        val originalScale = prefs.uiTextScale.first()
        val originalTab = prefs.preferredStartTab.first()
        val originalEink = eink.state.value.mode
        val originalFont = Settings.System.getFloat(context.contentResolver, Settings.System.FONT_SCALE, 1f)
        try {
            prefs.setPreferredStartTab(HearthStartTab.LIBRARY)
            eink.setMode(EinkMode.OFF)
            prefs.setThemeMode(HearthThemeMode.INK)
            prefs.setOledEnabled(true)
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                assertControls()
                screenshot("library-oled")
                compose.onNodeWithContentDescription("More library options").performClick()
                compose.onNodeWithText("Refresh sources").assertIsDisplayed()
                compose.onNodeWithText("Settings").assertIsDisplayed()
                pressBack()
                compose.onNodeWithContentDescription("Shelves").performClick()
                compose.onNodeWithText("Everything").assertIsDisplayed()
                compose.onNodeWithText("Downloaded").assertIsDisplayed()
                pressBack()

                prefs.setThemeMode(HearthThemeMode.PAPER)
                prefs.setUiTextScale(1.3f)
                setFontScale(1.5f)
                delay(1_500)
                assertControls()
                filter().performClick()
                assertSortHeader()
                screenshot("library-paper-large-sort")
                compose.onNodeWithText("Done").performClick()
                screenshot("library-paper-large")

                setFontScale(originalFont)
                prefs.setUiTextScale(originalScale)
                scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
                withTimeout(10_000) {
                    while (context.resources.configuration.orientation != Configuration.ORIENTATION_LANDSCAPE) delay(100)
                }
                assertControls()
                screenshot("library-landscape")
                scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
                withTimeout(10_000) {
                    while (context.resources.configuration.orientation != Configuration.ORIENTATION_PORTRAIT) delay(100)
                }
                eink.setMode(EinkMode.ON)
                delay(600)
                assertControls()
                filter().performClick()
                assertSortHeader()
                screenshot("library-eink-sort")
            }
        } finally {
            setFontScale(originalFont)
            eink.setMode(originalEink)
            prefs.setThemeMode(originalTheme)
            prefs.setOledEnabled(originalOled)
            prefs.setUiTextScale(originalScale)
            prefs.setPreferredStartTab(originalTab)
        }
    }

    private fun filter() = compose.onNodeWithContentDescription("Filter & Sort")

    private fun assertDefaultOrder() {
        val label = "Default order: recent books first."
        compose.waitUntil(timeoutMillis = 5_000) {
            compose.onAllNodesWithText(label, useUnmergedTree = true).fetchSemanticsNodes().size == 1
        }
        compose.onNodeWithText(label, useUnmergedTree = true).performScrollTo().assertIsDisplayed()
    }

    private fun assertSortHeader() {
        compose.waitUntil(timeoutMillis = 5_000) {
            runCatching {
                compose.onNodeWithText("SORT PRIORITY").assertIsDisplayed()
                true
            }.getOrDefault(false)
        }
    }

    private fun assertControls() {
        listOf("Add a source", "More library options", "Source", "Library", "Shelves", "Filter & Sort").forEach { description ->
            compose.onNode(hasContentDescription(description)).assertIsDisplayed()
                .assertHeightIsAtLeast(48.dp).assertWidthIsAtLeast(48.dp)
        }
    }

    private fun setFontScale(scale: Float) {
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("settings put system font_scale $scale").use {
            ParcelFileDescriptor.AutoCloseInputStream(it).readBytes()
        }
    }

    private fun screenshot(name: String) {
        compose.waitForIdle()
        android.os.SystemClock.sleep(400)
        val directory = File(context.getExternalFilesDir(null), "parity-verification").apply { mkdirs() }
        InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot().let { bitmap ->
            File(directory, "$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
    }
}
