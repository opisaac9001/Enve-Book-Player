package com.enve.app.profiles

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.MainActivity
import com.enve.core.data.local.FamilyProfileRole
import com.enve.engine.theme.HearthThemeMode
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProfileSwitchUiTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test fun paperProfileScreenAndDelayedSwitchStayVisible() = checkSwitch(false)

    @Test fun einkProfileScreenAndDelayedSwitchStayVisible() = checkSwitch(true)

    private fun checkSwitch(eink: Boolean) {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            lateinit var coordinator: ProfileSwitchCoordinator
            lateinit var lifecycle: ProfileLifecycleRegistry
            scenario.onActivity { coordinator = it.profiles; lifecycle = it.profileLifecycle }
            compose.waitUntil(20000) { coordinator.activeRuntime.value != null }
            val original = coordinator.activeRuntime.value!!
            val preferences = original.component.preferencesFacade()
            val originalMode = runBlocking { preferences.themeMode.first() }
            val einkFacade = original.component.einkFacade()
            val originalEink = einkFacade.state.value.mode
            val originalName = coordinator.state.value.profiles.first { it.id == original.profileId }.name
            val wasEnabled = coordinator.state.value.enabled
            val release = CompletableDeferred<Unit>()
            var targetId: String? = null
            var registration: AutoCloseable? = null
            try {
                runBlocking {
                    preferences.setThemeMode(if (eink) HearthThemeMode.INK else HearthThemeMode.PAPER)
                    einkFacade.setMode(if (eink) com.enve.engine.eink.EinkMode.ON else com.enve.engine.eink.EinkMode.OFF)
                    if (!wasEnabled) coordinator.setupOwner(originalName, null, null)
                    targetId = coordinator.addProfile("Switch UI test", FamilyProfileRole.ADULT).id
                }
                compose.waitUntil(10000) { compose.onAllNodesWithContentDescription("Profiles, $originalName").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithContentDescription("Profiles, $originalName").performClick()
                compose.waitUntil(10000) { compose.onAllNodesWithText("Use Switch UI test").fetchSemanticsNodes().isNotEmpty() }
                assertLightBackground()
                registration = lifecycle.register(original.profileId) { release.await() }
                compose.onNodeWithText("Use Switch UI test").performScrollTo().performClick()
                compose.waitUntil(10000) { compose.onAllNodesWithText("Switching profiles").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText("Switching profiles").assertIsDisplayed()
                assertLightBackground()
                release.complete(Unit)
                compose.waitUntil(30000) { coordinator.activeRuntime.value?.profileId == targetId && !coordinator.state.value.switching }
                compose.waitUntil(10000) { compose.onAllNodesWithContentDescription("Profiles, Switch UI test").fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithContentDescription("Profiles, Switch UI test").assertIsDisplayed()
            } finally {
                release.complete(Unit)
                registration?.close()
                runBlocking {
                    coordinator.switchProfile(original.profileId)
                    targetId?.let { coordinator.removeProfile(it) }
                    coordinator.activeRuntime.value!!.component.preferencesFacade().setThemeMode(originalMode)
                    coordinator.activeRuntime.value!!.component.einkFacade().setMode(originalEink)
                    if (!wasEnabled) coordinator.disableProfiles()
                }
            }
        }
    }

    private fun assertLightBackground() {
        var dismissed = false
        compose.waitUntil(10000) {
            if (!dismissed && compose.onAllNodesWithText("Maybe later").fetchSemanticsNodes().isNotEmpty()) {
                compose.onNodeWithText("Maybe later").performClick()
                dismissed = true
            }
            val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
            try {
                androidx.core.graphics.ColorUtils.calculateLuminance(bitmap.getPixel(2, bitmap.height / 2)) > 0.6
            } finally { bitmap.recycle() }
        }
    }
}
