package com.enve.app.ui.screens

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
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
