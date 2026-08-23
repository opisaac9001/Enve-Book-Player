package com.enve.app.playback

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PlayerSleepTimerService @Inject constructor() {

    fun start(
        scope: CoroutineScope,
        minutes: Int,
        isFadeEnabled: () -> Boolean,
        onTick: (remainingSec: Long) -> Unit,
        onFade: (volume: Float) -> Unit,
        onFinished: suspend () -> Unit,
    ): Job = startSeconds(scope, minutes * 60L, isFadeEnabled, onTick, onFade, onFinished)

    fun startSeconds(
        scope: CoroutineScope,
        seconds: Long,
        isFadeEnabled: () -> Boolean,
        onTick: (remainingSec: Long) -> Unit,
        onFade: (volume: Float) -> Unit,
        onFinished: suspend () -> Unit,
    ): Job {
        val totalSeconds = seconds.coerceAtLeast(0L)
        return scope.launch {
            var remaining = totalSeconds
            onTick(remaining)

            while (remaining > 0 && isActive) {
                delay(1000)
                remaining--
                onTick(remaining)

                if (isFadeEnabled() && remaining in 1..30) {
                    onFade((remaining.toFloat() / 30f).coerceIn(0f, 1f))
                }
            }

            if (remaining <= 0 && isActive) {
                onFinished()
            }
        }
    }

    fun startUntil(
        scope: CoroutineScope,
        remainingSeconds: () -> Long,
        isFadeEnabled: () -> Boolean,
        onTick: (remainingSec: Long) -> Unit,
        onFade: (volume: Float) -> Unit,
        onFinished: suspend () -> Unit,
    ): Job = scope.launch {
        var fading = false
        while (isActive) {
            val remaining = remainingSeconds().coerceAtLeast(0L)
            onTick(remaining)

            if (remaining == 0L) {
                onFinished()
                return@launch
            }

            if (isFadeEnabled() && remaining <= 30L) {
                fading = true
                onFade((remaining.toFloat() / 30f).coerceIn(0f, 1f))
            } else if (fading) {
                fading = false
                onFade(1f)
            }
            delay(250)
        }
    }
}
