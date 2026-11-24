package com.enve.app.cloud

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.test.espresso.Espresso
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.engine.readwise.ReadwiseExportPreview
import com.enve.engine.readwise.ReadwiseExportProgress
import com.enve.engine.readwise.ReadwiseExportResult
import com.enve.engine.readwise.ReadwiseExportScope
import com.enve.engine.readwise.ReadwiseFacade
import com.enve.engine.readwise.ReadwiseFailure
import com.enve.engine.readwise.ReadwisePreviewHighlight
import com.enve.hearth.design.HearthTheme
import com.enve.hearth.readwise.HearthReadwiseScreen
import com.enve.hearth.readwise.ReadwiseViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReadwiseScreenTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun connectPreviewCancelThenExplicitlySend() {
        val facade = FixtureReadwise()
        val vm = ReadwiseViewModel(facade)
        compose.setContent {
            HearthTheme { HearthReadwiseScreen(ReadwiseExportScope.AllBooks, onBack = {}, vm = vm) }
        }
        compose.onNodeWithText("Access token").performTextInput("offline-fixture-token")
        Espresso.closeSoftKeyboard()
        compose.onNodeWithText("Connect", substring = false).performScrollTo().performClick()
        compose.waitUntil(5_000) { facade.isConnected.value }
        compose.onNodeWithText("Send 1 highlight to Readwise").performScrollTo().performClick()
        compose.onNodeWithText("Cancel", substring = false).performClick()
        assertEquals(0, facade.exports)
        compose.onNodeWithText("Send 1 highlight to Readwise").performClick()
        compose.onNodeWithText("Send", substring = false).performClick()
        compose.waitUntil(5_000) { facade.exports == 1 }
        compose.onNodeWithText("Sent 1 highlight to Readwise.").assertIsDisplayed()
        compose.onNodeWithText("Disconnect").performScrollTo().performClick()
        compose.onNodeWithText("Access token").assertIsDisplayed()
    }

    private class FixtureReadwise : ReadwiseFacade {
        override val isConnected = MutableStateFlow(false)
        var exports = 0

        override suspend fun connect(token: String): ReadwiseFailure? {
            assertEquals("offline-fixture-token", token)
            isConnected.value = true
            return null
        }

        override suspend fun validate(): ReadwiseFailure? = null
        override fun disconnect() { isConnected.value = false }

        override suspend fun preview(scope: ReadwiseExportScope) = ReadwiseExportPreview(
            scope, bookCount = 1, newCount = if (exports == 0) 1 else 0, changedCount = 0,
            alreadySentCount = exports, excludedCount = 0,
            samples = listOf(ReadwisePreviewHighlight("Test book", "Enve test", "A local test highlight.", null)),
        )

        override suspend fun export(scope: ReadwiseExportScope, onProgress: (ReadwiseExportProgress) -> Unit): ReadwiseExportResult {
            exports++
            onProgress(ReadwiseExportProgress(1, 1))
            return ReadwiseExportResult(1, 0, null)
        }
    }
}
