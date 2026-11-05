package com.enve.app.listeningposition

import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.view.Surface
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.engine.prefs.HearthStartTab
import dagger.hilt.android.EntryPointAccessors
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ListeningPositionRouteRotationTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun libraryScannerRemainsPresentedAfterActivityRotates(): Unit = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        val component = ActivityScenario.launch(MainActivity::class.java).use {
            withTimeout(20_000) { while (coordinator.activeRuntime.value == null) delay(100) }
            checkNotNull(coordinator.activeRuntime.value).component
        }
        val preferences = component.preferencesFacade()
        val originalTab = preferences.preferredStartTab.first()
        try {
            preferences.setPreferredStartTab(HearthStartTab.LIBRARY)
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                var originalOrientation = Configuration.ORIENTATION_UNDEFINED
                var originalRotation = Surface.ROTATION_0
                scenario.onActivity {
                    originalOrientation = it.resources.configuration.orientation
                    originalRotation = it.window.decorView.display.rotation
                }
                try {
                    scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
                    compose.waitUntil(10_000) {
                        compose.onAllNodesWithContentDescription("More library options").fetchSemanticsNodes().isNotEmpty()
                    }
                    compose.onNodeWithContentDescription("More library options").performClick()
                    compose.onNodeWithText("Scan book position").performClick()
                    compose.onNodeWithText("Scan book position", ignoreCase = true).assertIsDisplayed()
                    scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
                    compose.waitUntil(10_000) {
                        var orientation = Configuration.ORIENTATION_UNDEFINED
                        scenario.onActivity { orientation = it.resources.configuration.orientation }
                        orientation == Configuration.ORIENTATION_LANDSCAPE
                    }
                    compose.waitUntil(10_000) {
                        compose.onAllNodesWithText("Scan book position", ignoreCase = true).fetchSemanticsNodes().isNotEmpty()
                    }
                    compose.onNodeWithText("Scan book position", ignoreCase = true).assertIsDisplayed()
                    compose.onNodeWithText("Choose an image").assertExists()
                } finally {
                    val requested = when (originalRotation) {
                        Surface.ROTATION_90 -> ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
                        Surface.ROTATION_180 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_PORTRAIT
                        Surface.ROTATION_270 -> ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
                        else -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
                    }
                    scenario.onActivity { it.requestedOrientation = requested }
                    compose.waitUntil(10_000) {
                        var restored = false
                        scenario.onActivity {
                            restored = it.resources.configuration.orientation == originalOrientation &&
                                it.window.decorView.display.rotation == originalRotation
                        }
                        restored
                    }
                }
            }
        } finally {
            preferences.setPreferredStartTab(originalTab)
        }
    }
}
