package com.enve.app.playback.sleep

import android.content.Context
import com.enve.app.playback.ProfileJsonFile
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.engine.playback.SleepAutomationSettings
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

private const val SLEEP_AUTOMATION_FILE = "playback/sleep-automation.json"

@Singleton
class SleepAutomationStore @Inject constructor(
    @ApplicationContext context: Context,
    locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
) {
    private val file = ProfileJsonFile(
        File(locations.filesDirectory, SLEEP_AUTOMATION_FILE),
        SleepAutomationSettings.serializer(),
    ) { SleepAutomationSettings() }
    private val mutex = Mutex()
    private val _settings = MutableStateFlow(SleepAutomationSettings())
    val settings: StateFlow<SleepAutomationSettings> = _settings.asStateFlow()

    private var loaded = false

    suspend fun load() = mutex.withLock { ensureLoaded() }

    suspend fun update(settings: SleepAutomationSettings) = mutex.withLock {
        ensureLoaded()
        val sanitized = settings.copy(
            autoSleepStartMinutes = settings.autoSleepStartMinutes.coerceIn(0, MINUTES_PER_DAY - 1),
            autoSleepEndMinutes = settings.autoSleepEndMinutes.coerceIn(0, MINUTES_PER_DAY - 1),
            autoSleepTimerMinutes = settings.autoSleepTimerMinutes.coerceIn(1, 240),
            snoozeMinutes = settings.snoozeMinutes.coerceIn(1, 60),
        )
        file.write(sanitized)
        _settings.value = sanitized
    }

    private suspend fun ensureLoaded() {
        if (loaded) return
        _settings.value = file.read()
        loaded = true
    }
}
