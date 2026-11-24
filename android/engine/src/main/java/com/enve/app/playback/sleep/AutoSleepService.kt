package com.enve.app.playback.sleep

import android.util.Log
import com.enve.app.playback.AudioPlaybackManager
import com.enve.core.di.ApplicationScope
import com.enve.engine.playback.PlayerSessionFacade
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.merge
import kotlinx.coroutines.launch
import java.io.IOException
import java.time.LocalDateTime
import javax.inject.Inject
import javax.inject.Singleton

internal const val MINUTES_PER_DAY = 24 * 60

internal object AutoSleepPolicy {
    fun isInWindow(minutesOfDay: Int, start: Int, end: Int): Boolean {
        if (start == end) return false
        if (start < end) return minutesOfDay in start until end
        return minutesOfDay >= start || minutesOfDay < end
    }

    fun currentWindowStart(now: LocalDateTime, startMinutes: Int): LocalDateTime {
        val todayStart = now.toLocalDate().atStartOfDay().plusMinutes(startMinutes.toLong())
        return if (!now.isBefore(todayStart)) todayStart else todayStart.minusDays(1)
    }

    fun snoozeMinutes(remainingSec: Long?, snoozeMinutes: Int): Int? =
        snoozeMinutes.takeIf { remainingSec != null && remainingSec in 1 until it * 60L }
}

@Singleton
class AutoSleepService @Inject constructor(
    private val store: SleepAutomationStore,
    private val shakeDetection: ShakeDetectionService,
    private val audioManager: AudioPlaybackManager,
    private val session: PlayerSessionFacade,
    @ApplicationScope parentScope: CoroutineScope,
) {
    private val scope = CoroutineScope(SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.Main)
    private var armedWindowStart: LocalDateTime? = null
    private var started = false

    fun start() {
        if (started) return
        started = true
        scope.launch {
            try {
                store.load()
            } catch (error: IOException) {
                Log.w(TAG, "Sleep automation settings are unreadable", error)
                return@launch
            }
            launch { autoArm() }
            launch { snoozeOnShake() }
        }
    }

    private suspend fun autoArm() {
        val playbackStarted = audioManager.state.map { it.isPlaying }.distinctUntilChanged().filter { it }.map { }
        val settingsChanged = store.settings.drop(1).map { }
        val minuteTicks = flow {
            while (true) {
                emit(Unit)
                delay(60_000L)
            }
        }
        merge(playbackStarted, settingsChanged, minuteTicks).collect { evaluate(LocalDateTime.now()) }
    }

    private suspend fun snoozeOnShake() {
        combine(
            store.settings.map { it.shakeToSnoozeEnabled },
            session.sleepRemainingSec.map { it != null },
        ) { enabled, timerRunning -> enabled && timerRunning && shakeDetection.isAvailable }
            .distinctUntilChanged()
            .collectLatest { listening ->
                if (!listening) return@collectLatest
                shakeDetection.shakes().collect {
                    AutoSleepPolicy.snoozeMinutes(session.sleepRemainingSec.value, store.settings.value.snoozeMinutes)
                        ?.let(session::startSleepTimer)
                }
            }
    }

    private fun evaluate(now: LocalDateTime) {
        val settings = store.settings.value
        if (!settings.autoSleepEnabled) {
            armedWindowStart = null
            return
        }
        if (!audioManager.state.value.isPlaying) return
        val minutesOfDay = now.hour * 60 + now.minute
        if (!AutoSleepPolicy.isInWindow(minutesOfDay, settings.autoSleepStartMinutes, settings.autoSleepEndMinutes)) {
            armedWindowStart = null
            return
        }
        val windowStart = AutoSleepPolicy.currentWindowStart(now, settings.autoSleepStartMinutes)
        if (armedWindowStart == windowStart) return
        armedWindowStart = windowStart
        if (session.sleepRemainingSec.value != null) return
        session.startSleepTimer(settings.autoSleepTimerMinutes)
    }

    private companion object {
        const val TAG = "AutoSleepService"
    }
}
