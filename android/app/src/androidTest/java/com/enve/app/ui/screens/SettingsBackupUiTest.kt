package com.enve.app.ui.screens

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import com.enve.engine.backup.SettingsCodeOffer
import com.enve.engine.backup.SettingsTransferFacade
import com.enve.engine.backup.SettingsTransferOffer
import com.enve.engine.backup.SettingsTransferReview
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.MutableStateFlow
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.engine.backup.SettingsBackup
import com.enve.engine.backup.SettingsBackupChange
import com.enve.engine.backup.SettingsBackupFacade
import com.enve.engine.backup.SettingsExportResult
import com.enve.engine.backup.SettingsImportInspection
import com.enve.engine.backup.SettingsImportPreview
import com.enve.hearth.design.HearthTheme
import com.enve.hearth.settings.SettingsBackupScreen
import com.enve.hearth.settings.SettingsBackupViewModel
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SettingsBackupUiTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun previewRequiresConfirmationAndCancelDoesNotApply() {
        val facade = BackupFixture()
        val vm = SettingsBackupViewModel(facade)
        compose.setContent { HearthTheme { SettingsBackupScreen(onBack = {}, vm = vm) } }
        compose.runOnIdle { vm.inspect("content://test/backup") }
        compose.onNodeWithText("Import 1 change?").assertIsDisplayed()
        compose.onNodeWithText("30 s → 45 s").assertIsDisplayed()
        compose.runOnIdle { assertEquals(0, facade.applied) }
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Import 1 change?").assertDoesNotExist()
        compose.runOnIdle {
            assertEquals(0, facade.applied)
            vm.inspect("content://test/backup")
        }
        compose.onNodeWithText("Import", useUnmergedTree = true).performClick()
        compose.runOnIdle { assertEquals(1, facade.applied) }
        compose.onNodeWithText("Imported 1 setting.").assertExists()
    }

    @Test
    fun qrRequiresExplicitConfirmationBeforeIncludingSignIns() {
        val transfer = TransferFixture()
        val vm = SettingsBackupViewModel(BackupFixture(), transfer)
        compose.setContent { HearthTheme { SettingsBackupScreen(onBack = {}, vm = vm) } }

        compose.onNodeWithText("Transfer to another device").performClick()
        compose.onNodeWithText("Include supported sign-ins").performClick()
        compose.onNodeWithText("Show QR code").performClick()
        compose.onNodeWithText("Share your saved sign-ins?").assertIsDisplayed()
        compose.onNodeWithContentDescription("One-time transfer QR code").assertDoesNotExist()
        compose.runOnIdle { assertEquals(emptyList<Boolean>(), transfer.requests) }
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { assertEquals(emptyList<Boolean>(), transfer.requests) }

        compose.onNodeWithText("Transfer to another device").performClick()
        compose.onNodeWithText("Include supported sign-ins").performClick()
        compose.onNodeWithText("Show QR code").performClick()
        compose.onNodeWithText("Transfer without sign-ins").performClick()
        compose.onNodeWithContentDescription("One-time transfer QR code").assertExists()
        compose.runOnIdle { assertEquals(listOf(false), transfer.requests) }
    }

    @Test
    fun typedCodeRequiresSignInConsentAndSenderApproval() {
        val transfer = TransferFixture()
        val vm = SettingsBackupViewModel(BackupFixture(), transfer)
        compose.setContent { HearthTheme { SettingsBackupScreen(onBack = {}, vm = vm) } }

        compose.onNodeWithText("Transfer to another device").performClick()
        compose.onNodeWithText("Include supported sign-ins").performClick()
        compose.onNodeWithText("Show six-digit code").performClick()
        compose.onNodeWithText("Share your saved sign-ins?").assertIsDisplayed()
        compose.onNodeWithText("004201").assertDoesNotExist()
        compose.onNodeWithText("Show code with sign-ins").performClick()
        compose.onNodeWithText("004201").assertIsDisplayed()
        compose.onNodeWithText("Approve transfer").assertDoesNotExist()
        compose.runOnIdle {
            assertEquals(listOf(true), transfer.requests)
            transfer.awaitingApproval.value = true
        }
        compose.onNodeWithText("Approve transfer").performClick()
        compose.runOnIdle { assertEquals(1, transfer.approvals) }
    }

    private class TransferFixture : SettingsTransferFacade {
        val requests = mutableListOf<Boolean>()
        val awaitingApproval = MutableStateFlow(false)
        var approvals = 0

        override suspend fun send(
            includeSettings: Boolean, includeSources: Boolean, includeIntegrations: Boolean, includeSignIns: Boolean,
        ): SettingsTransferOffer {
            requests += includeSignIns
            return object : SettingsTransferOffer {
                override val code = "test-only QR fixture"
                override suspend fun awaitTransfer(): Unit = awaitCancellation()
                override fun close() = Unit
            }
        }

        override suspend fun sendCode(
            includeSettings: Boolean, includeSources: Boolean, includeIntegrations: Boolean, includeSignIns: Boolean,
        ): SettingsCodeOffer {
            requests += includeSignIns
            return object : SettingsCodeOffer {
                override val code = "004201"
                override val awaitingApproval = this@TransferFixture.awaitingApproval
                override fun approve() { approvals++ }
                override suspend fun awaitTransfer(): Unit = awaitCancellation()
                override fun close() = Unit
            }
        }

        override suspend fun receive(code: String): SettingsTransferReview = error("Unexpected receive")
        override suspend fun receiveCode(code: String): SettingsTransferReview = error("Unexpected code")
        override suspend fun exportFile(
            uri: String, includeSettings: Boolean, includeSources: Boolean, includeIntegrations: Boolean,
            includeSignIns: Boolean, passphrase: String,
        ) = error("Unexpected export")
        override suspend fun importFile(uri: String, passphrase: String): SettingsTransferReview = error("Unexpected import")
    }

    private class BackupFixture : SettingsBackupFacade {
        var applied = 0
        override suspend fun export(destinationUri: String) = SettingsExportResult.Exported(1)
        override suspend fun inspect(sourceUri: String) = SettingsImportInspection.Ready(
            SettingsImportPreview(
                backup = SettingsBackup(skipForwardSeconds = 45),
                exportedAtMillis = null,
                changes = listOf(SettingsBackupChange("Skip forward", "30 s", "45 s")),
                unchangedCount = 0,
                ignoredKeys = emptyList(),
            ),
        )
        override suspend fun apply(backup: SettingsBackup): Boolean {
            applied++
            return true
        }
    }
}
