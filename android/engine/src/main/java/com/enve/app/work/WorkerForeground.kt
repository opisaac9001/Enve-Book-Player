package com.enve.app.work

import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import kotlinx.coroutines.CancellationException

internal suspend fun CoroutineWorker.enterForeground(info: ForegroundInfo): Boolean = try {
    setForeground(info)
    true
} catch (cancelled: CancellationException) {
    throw cancelled
} catch (_: IllegalStateException) {
    false
}
