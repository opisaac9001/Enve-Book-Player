package com.enve.app.data.local

import android.content.Context
import android.content.ContextWrapper
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import org.junit.Assume.assumeTrue
import com.enve.app.profiles.ProfileRuntimeRegistry
import com.enve.engine.backup.SettingsCodeOffer
import com.enve.engine.backup.SettingsExportResult
import com.enve.engine.backup.SettingsImportInspection
import com.enve.engine.theme.HearthThemeMode
import java.io.File
import java.util.UUID
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SettingsBackupIntegrationTest {
    @Test
    fun backupRestoresOnlyTheDestinationProfileAndSurvivesReopen() = runBlocking {
        val context = BackupTestContext(ApplicationProvider.getApplicationContext())
        val runtimes = ProfileRuntimeRegistry(context)
        val sourceId = UUID.randomUUID().toString()
        val targetId = UUID.randomUUID().toString()
        try {
            val source = runtimes.open(sourceId)
            val target = runtimes.open(targetId)
            source.preferencesFacade().setThemeMode(HearthThemeMode.PAPER)
            source.preferencesFacade().setSkipForwardSeconds(45)
            source.preferencesFacade().setDefaultSpeed(1.75f)
            target.preferencesFacade().setThemeMode(HearthThemeMode.INK)
            target.preferencesFacade().setSkipForwardSeconds(10)
            val file = File(context.cacheDir, "settings.json")
            val uri = Uri.fromFile(file).toString()
            assertTrue(source.settingsBackup().export(uri) is SettingsExportResult.Exported)
            val exported = file.readText()
            assertFalse(exported.contains("accessToken", ignoreCase = true))
            assertFalse(exported.contains("serverUrl", ignoreCase = true))
            val preview = target.settingsBackup().inspect(uri) as SettingsImportInspection.Ready
            assertTrue(preview.preview.changes.isNotEmpty())
            assertEquals(10, target.preferencesFacade().skipForwardSeconds.first())
            assertTrue(target.settingsBackup().apply(preview.preview.backup))
            assertEquals(45, target.preferencesFacade().skipForwardSeconds.first())
            assertEquals(1.75f, target.preferencesFacade().defaultSpeed.first())
            target.preferencesFacade().setSkipForwardSeconds(20)
            assertEquals(45, source.preferencesFacade().skipForwardSeconds.first())
            runtimes.close(targetId)
            val reopened = runtimes.open(targetId)
            assertEquals(20, reopened.preferencesFacade().skipForwardSeconds.first())
            assertEquals(HearthThemeMode.PAPER, reopened.preferencesFacade().themeMode.first())
            assertEquals(1.75f, reopened.preferencesFacade().defaultSpeed.first())

            file.writeText("""{"format":"enve.android.settings","version":1,"settings":{"skipForwardSeconds":60,"defaultSpeed":-1}}""")
            assertTrue(reopened.settingsBackup().inspect(uri) is SettingsImportInspection.Rejected)
            assertEquals(20, reopened.preferencesFacade().skipForwardSeconds.first())
        } finally {
            runtimes.close(sourceId)
            runtimes.close(targetId)
            context.clear()
        }
    }

    @Test
    fun sendsIsolatedAndroidSettingsToCrossPlatformPeer() = runBlocking {
        val mode = InstrumentationRegistry.getArguments().getString("enveTransferPeer")
        assumeTrue(mode == "true" || mode == "code")
        val target = ApplicationProvider.getApplicationContext<Context>()
        val context = BackupTestContext(target)
        val runtimes = ProfileRuntimeRegistry(context)
        val marker = File(target.cacheDir, "enve-transfer-fixture-code")
        try {
            val source = runtimes.open(DEFAULT_ADULT_PROFILE_ID)
            source.preferencesFacade().setThemeMode(HearthThemeMode.PAPER)
            source.preferencesFacade().setSkipForwardSeconds(45)
            val transfer = source.settingsTransfer()
            val offered = if (mode == "code") {
                transfer.sendCode(includeSettings = true, includeSources = false, includeIntegrations = false, includeSignIns = false)
            } else {
                transfer.send(includeSettings = true, includeSources = false, includeIntegrations = false, includeSignIns = false)
            }
            offered.use { offer ->
                val approval = (offer as? SettingsCodeOffer)?.let { typed ->
                    launch {
                        typed.awaitingApproval.first { it }
                        typed.approve()
                    }
                }
                try {
                    marker.writeText(offer.code)
                    offer.awaitTransfer()
                } finally {
                    approval?.cancel()
                }
            }
        } finally {
            marker.delete()
            runtimes.close(DEFAULT_ADULT_PROFILE_ID)
            context.clear()
        }
    }

    @Test
    fun receivesTypedCodeFromCrossPlatformPeer() = runBlocking {
        val code = InstrumentationRegistry.getArguments().getString("enveTransferCode")
        assumeTrue(code != null)
        val verifiedCode = checkNotNull(code)
        val context = BackupTestContext(ApplicationProvider.getApplicationContext())
        val runtimes = ProfileRuntimeRegistry(context)
        try {
            val target = runtimes.open(DEFAULT_ADULT_PROFILE_ID)
            target.preferencesFacade().setSkipForwardSeconds(10)
            val transfer = target.settingsTransfer()
            val incorrect = verifiedCode.dropLast(1) + if (verifiedCode.last() == '0') "1" else "0"
            try {
                transfer.receiveCode(incorrect)
                throw AssertionError("The wrong code received a backup")
            } catch (_: java.io.IOException) {}
            val review = transfer.receiveCode(verifiedCode)
            assertEquals(10, target.preferencesFacade().skipForwardSeconds.first())
            assertTrue(review.restore(settings = true, sourceIds = emptySet(), integrationIds = emptySet()).settingsSaved)
            assertEquals(45, target.preferencesFacade().skipForwardSeconds.first())
        } finally {
            runtimes.close(DEFAULT_ADULT_PROFILE_ID)
            context.clear()
        }
    }

    private class BackupTestContext(base: Context) : ContextWrapper(base) {
        private val prefix = "settings-backup-test-${UUID.randomUUID()}-"
        private val root = File(base.cacheDir, prefix).also { check(it.mkdirs()) }
        private val preferences = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = File(root, "files").also { it.mkdirs() }
        override fun getCacheDir(): File = File(root, "cache").also { it.mkdirs() }
        override fun getDatabasePath(name: String): File = File(root, "databases/$name").also {
            checkNotNull(it.parentFile).mkdirs()
        }
        override fun getSharedPreferences(name: String, mode: Int) =
            baseContext.getSharedPreferences(prefix + name, mode).also { preferences += prefix + name }

        fun clear() {
            preferences.forEach(baseContext::deleteSharedPreferences)
            root.deleteRecursively()
        }
    }
}
