package com.enve.app.ui.screens

import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.viewmodel.PendingSyncStatus
import com.enve.app.viewmodel.SyncCenterState
import com.enve.core.data.local.PendingProgressPush
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SyncRecoveryUiTest {
    @get:Rule val compose = createComposeRule()

    private val checkpoint = PendingProgressPush(
        bookId = "book-1",
        source = BookSource.AUDIOBOOKSHELF.name,
        connectionKey = "conn-1",
        mediaType = "AUDIOBOOK",
        percentage = 0.42f,
        isFinished = false,
        createdAt = 1_700_000_000_000L,
    )
    private val update = PendingSyncStatus(checkpoint, "The Hobbit", "Home Shelf")

    private val retried = mutableListOf<PendingProgressPush>()
    private val discarded = mutableListOf<PendingProgressPush>()

    private fun show(initial: SyncCenterState) = mutableStateOf(initial).also { state ->
        compose.setContent {
            EnveTheme(dynamicBackgroundEnabled = false) {
                SyncCenterScreen(
                    state = state.value,
                    onBack = {},
                    onSyncNow = {},
                    onAutoSyncChange = {},
                    onSyncOnCellularChange = {},
                    onKoreaderUsernameChange = {},
                    onKoreaderPasswordChange = {},
                    onSaveKoreaderCredentials = {},
                    onTestKoreaderAuth = {},
                    onClearKoreaderCredentials = {},
                    onRetryPending = { retried += it },
                    onDiscardPending = { discarded += it },
                    onOpenBackup = {},
                )
            }
        }
    }

    private fun pending(vararg updates: PendingSyncStatus) =
        SyncCenterState(pendingUpdates = updates.toList(), pendingCount = updates.size)

    @Test
    fun emptyQueueExplainsNothingIsWaitingWithoutClaimingDelivery() {
        show(SyncCenterState())
        compose.onNodeWithTag(SYNC_RECOVERY_EMPTY_TAG).performScrollTo().assertIsDisplayed()
        compose.onNodeWithTag(SYNC_RECOVERY_ROW_TAG).assertDoesNotExist()
        compose.onNodeWithText("Up to Date").assertDoesNotExist()
    }

    @Test
    fun queuedUpdateShowsTitleDestinationMediaAndCoercedPercent() {
        show(pending(update.copy(checkpoint = checkpoint.copy(percentage = 1.7f))))
        compose.onNodeWithTag(SYNC_RECOVERY_ROW_TAG).performScrollTo()
        compose.onNodeWithText("The Hobbit").assertIsDisplayed()
        compose.onNodeWithText("Home Shelf • Audiobook • 100%").assertIsDisplayed()
        compose.onNodeWithTag(SYNC_RECOVERY_STATUS_TAG, useUnmergedTree = true).assertIsDisplayed()
    }

    @Test
    fun invalidPercentIsOmitted() {
        show(pending(update.copy(checkpoint = checkpoint.copy(percentage = Float.NaN))))
        compose.onNodeWithTag(SYNC_RECOVERY_ROW_TAG).performScrollTo()
        compose.onNodeWithText("Home Shelf • Audiobook").assertIsDisplayed()
    }

    @Test
    fun unsanitizedErrorsAreReplacedWithGenericGuidance() {
        val leaky = "failed to connect to /192.168.1.20:13378 after 10000ms"
        show(pending(update.copy(checkpoint = checkpoint.copy(lastError = leaky, lastAttemptAt = 1L))))
        compose.onNodeWithTag(SYNC_RECOVERY_ROW_TAG).performScrollTo()
        compose.onNodeWithText(leaky, substring = true).assertDoesNotExist()
        compose.onNodeWithText("This update couldn't be sent yet. Check the connection and retry.").assertIsDisplayed()
    }

    @Test
    fun knownReplayMessagesAreShownVerbatim() {
        val safe = "Refresh this book's library before retrying."
        show(pending(update.copy(checkpoint = checkpoint.copy(lastError = safe, lastAttemptAt = 1L))))
        compose.onNodeWithTag(SYNC_RECOVERY_ROW_TAG).performScrollTo()
        compose.onNodeWithText(safe).assertIsDisplayed()
    }

    @Test
    fun retrySendsTheRowCheckpoint() {
        show(pending(update))
        compose.onNodeWithTag(SYNC_RECOVERY_RETRY_TAG).performScrollTo().assertIsEnabled().performClick()
        compose.runOnIdle { assertEquals(listOf(checkpoint), retried) }
    }

    @Test
    fun retryIsDisabledWhilePausedRecoveringOrSyncing() {
        val state = show(pending(update).copy(serverSyncEnabled = false))
        compose.onNodeWithTag(SYNC_RECOVERY_PAUSED_TAG).performScrollTo().assertIsDisplayed()
        compose.onNodeWithContentDescription("Retry unavailable while server sync is off").assertIsNotEnabled()
        compose.onNodeWithText("Paused while server sync is off.").assertIsDisplayed()

        compose.runOnIdle { state.value = state.value.copy(serverSyncEnabled = true, isRecovering = true) }
        compose.onNodeWithTag(SYNC_RECOVERY_PAUSED_TAG).assertDoesNotExist()
        compose.onNodeWithTag(SYNC_RECOVERY_BUSY_TAG).assertExists()
        compose.onNodeWithTag(SYNC_RECOVERY_RETRY_TAG).assertIsNotEnabled()
        compose.onNodeWithTag(SYNC_RECOVERY_DISCARD_TAG).assertIsNotEnabled()

        compose.runOnIdle { state.value = state.value.copy(isRecovering = false, isSyncingAll = true) }
        compose.onNodeWithTag(SYNC_RECOVERY_RETRY_TAG).assertIsNotEnabled()

        compose.runOnIdle { state.value = state.value.copy(isSyncingAll = false) }
        compose.onNodeWithTag(SYNC_RECOVERY_RETRY_TAG).assertIsEnabled()
        compose.runOnIdle { assertEquals(emptyList<PendingProgressPush>(), retried) }
    }

    @Test
    fun discardRequiresConfirmationAndCanBeCancelled() {
        show(pending(update))
        compose.onNodeWithContentDescription("Discard queued update for The Hobbit").performScrollTo().performClick()
        compose.onNodeWithTag(SYNC_RECOVERY_CONFIRM_TAG).assertIsDisplayed()
        compose.onNodeWithText("reading progress on this device stays", substring = true).assertIsDisplayed()
        compose.runOnIdle { assertEquals(emptyList<PendingProgressPush>(), discarded) }

        compose.onNodeWithTag(SYNC_RECOVERY_CONFIRM_CANCEL_TAG).performClick()
        compose.onNodeWithTag(SYNC_RECOVERY_CONFIRM_TAG).assertDoesNotExist()
        compose.runOnIdle { assertEquals(emptyList<PendingProgressPush>(), discarded) }

        compose.onNodeWithTag(SYNC_RECOVERY_DISCARD_TAG).performScrollTo().performClick()
        compose.onNodeWithTag(SYNC_RECOVERY_CONFIRM_DISCARD_TAG).performClick()
        compose.onNodeWithTag(SYNC_RECOVERY_CONFIRM_TAG).assertDoesNotExist()
        compose.runOnIdle { assertEquals(listOf(checkpoint), discarded) }
    }

    @Test
    fun confirmationKeepsTheCheckpointCapturedWhenOpened() {
        val state = show(pending(update))
        compose.onNodeWithTag(SYNC_RECOVERY_DISCARD_TAG).performScrollTo().performClick()

        val newer = checkpoint.copy(percentage = 0.55f, createdAt = checkpoint.createdAt + 60_000L)
        compose.runOnIdle { state.value = pending(update.copy(checkpoint = newer)) }

        compose.onNodeWithTag(SYNC_RECOVERY_CONFIRM_DISCARD_TAG).performClick()
        compose.runOnIdle { assertEquals(listOf(checkpoint), discarded) }
    }
}
