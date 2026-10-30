package com.enve.app.listeningposition

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.MainActivity
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ListeningPositionMenuTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test fun libraryMenuOpensTheProfileBoundScannerAndClosesBackToLibrary() {
        ActivityScenario.launch(MainActivity::class.java).use {
            compose.waitUntil(20000) { compose.onAllNodesWithText("Library").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Library").performClick()
            compose.onNodeWithContentDescription("More library options").performClick()
            compose.onNodeWithText("Scan book position").performClick()
            compose.onNodeWithTag("listening-position-import").assertIsDisplayed()
            compose.onNodeWithText("Close").performClick()
            compose.onNodeWithContentDescription("More library options").assertIsDisplayed()
        }
    }
}
