package com.enve.app.ui.screens

import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.MainActivity
import com.enve.hearth.design.HearthTheme
import com.enve.hearth.design.HearthEink
import com.enve.engine.eink.EinkState
import com.enve.engine.theme.HearthThemeMode
import com.enve.hearth.library.LibraryImportNotice
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryImportNoticeTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test fun compactDetailsRetryAndDismissWorkInLightDarkAndEink() {
        for (mode in listOf("light", "dark", "eink")) {
            var retries = 0
            val visible = mutableStateOf(true)
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    activity.setContent {
                        HearthTheme(mode = if (mode == "dark") HearthThemeMode.INK else HearthThemeMode.PAPER,
                            eink = HearthEink(EinkState.Inactive.copy(active = mode == "eink", monochrome = mode == "eink"))) {
                            if (visible.value) LibraryImportNotice(
                                listOf("Komga · Comics" to "Access denied (HTTP 403).", "Audiobookshelf · Fiction" to "The connection failed or timed out."),
                                refreshing = false, onRetry = { retries++ }, onDismiss = { visible.value = false },
                            )
                        }
                    }
                }
                compose.onNodeWithText("Library import incomplete").assertIsDisplayed()
                compose.onNodeWithText("Access denied (HTTP 403).").assertDoesNotExist()
                compose.onNodeWithText("Show details").performClick()
                compose.onNodeWithText("Komga · Comics").assertIsDisplayed()
                compose.onNodeWithText("Access denied (HTTP 403).").assertIsDisplayed()
                compose.onNodeWithText("Hide details").performClick()
                compose.onNodeWithText("Komga · Comics").assertDoesNotExist()
                compose.onNodeWithText("Retry").performClick()
                assertEquals(1, retries)
                compose.onNodeWithText("Dismiss").performClick()
                compose.onNodeWithText("Library import incomplete").assertDoesNotExist()
            }
        }
    }
}
