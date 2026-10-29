package com.enve.app.ui.screens

import android.content.Context
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.app.viewmodel.ThemeViewModel
import com.enve.engine.prefs.EbookSyncInterval
import dagger.hilt.android.EntryPointAccessors
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class FeedbackPreferencesTest {
    @Test
    fun customColourAndFeedbackPreferencesSurviveReopening() = runBlocking<Unit> {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use {
            withTimeout(20_000) { while (coordinator.activeRuntime.value == null) delay(100) }
        }
        val component = checkNotNull(coordinator.activeRuntime.value).component
        val prefs = component.preferencesFacade()
        val originalAccent = component.preferences().themeColorHex.first()
        val originalDock = prefs.showDockBookShortcut.first()
        val originalOverview = prefs.showTodayStack.first()
        val originalInterval = prefs.ebookSyncInterval.first()
        val models = ViewModelStore()
        try {
            withContext(Dispatchers.Main) {
                val vm = ThemeViewModel(component.preferences(), component.einkManager())
                models.put("theme", vm)
                vm.setThemeColor(Color(0xFF3974AC))
            }
            withTimeout(5_000) { prefs.accentHex.first { it.equals("#3974AC", true) } }
            prefs.setShowDockBookShortcut(false)
            prefs.setShowTodayStack(false)
            prefs.setEbookSyncInterval(EbookSyncInterval.TWELVE_MINUTES)
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.recreate()
                assertEquals("#3974AC", prefs.accentHex.first())
                assertEquals(false, prefs.showDockBookShortcut.first())
                assertEquals(false, prefs.showTodayStack.first())
                assertEquals(EbookSyncInterval.TWELVE_MINUTES, prefs.ebookSyncInterval.first())
                val reopened = withContext(Dispatchers.Main) {
                    ThemeViewModel(component.preferences(), component.einkManager()).also { models.put("reopened", it) }
                }
                withTimeout(5_000) { reopened.themeState.first { it.themeColor.toArgb() == 0xFF3974AC.toInt() } }
            }
        } finally {
            withContext(Dispatchers.Main) { models.clear() }
            component.preferences().setThemeColorHex(originalAccent)
            prefs.setShowDockBookShortcut(originalDock)
            prefs.setShowTodayStack(originalOverview)
            prefs.setEbookSyncInterval(originalInterval)
        }
    }
}
