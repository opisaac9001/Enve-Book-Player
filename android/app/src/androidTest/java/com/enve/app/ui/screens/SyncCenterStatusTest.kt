package com.enve.app.ui.screens

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.viewmodel.SyncCenterState
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SyncCenterStatusTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun neverSyncedAndFailedSyncDoNotClaimToBeUpToDate() {
        val state = mutableStateOf(SyncCenterState())
        compose.setContent {
            EnveTheme(dynamicBackgroundEnabled = false) {
                SyncCenterScreen(state.value, {}, {}, {}, {}, {}, {}, {}, {}, {})
            }
        }
        compose.onNodeWithText("Not synced yet").assertIsDisplayed()
        compose.onNodeWithText("Last sync: Never").assertIsDisplayed()
        compose.onNodeWithText("Up to Date").assertDoesNotExist()
        compose.runOnIdle {
            state.value = state.value.copy(lastSyncTime = System.currentTimeMillis(), error = "Could not sync: Grimmory (Ebook)")
        }
        compose.onNodeWithText("Sync needs attention").assertIsDisplayed()
        compose.onNodeWithText("Up to Date").assertDoesNotExist()
        compose.runOnIdle { state.value = state.value.copy(error = null) }
        compose.onNodeWithText("Up to Date").assertIsDisplayed()
        compose.onNodeWithText("Last sync: Just now").assertIsDisplayed()
    }
}
