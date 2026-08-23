package com.enve.app.data.sync

import android.util.Log
import com.enve.core.data.sync.ProviderSyncStrategy
import javax.inject.Inject
import javax.inject.Singleton

enum class ServerStatusSyncTrigger {
    APP_LAUNCH,
    HOME_PULL_TO_REFRESH,
    MANUAL_SYNC,
}

data class ServerStatusSyncResult(
    val attemptedStrategyCount: Int,
    val pulledItemCount: Int,
    val pushedItemCount: Int,
    val failedStrategies: List<String>,
) {
    val mergedItemCount: Int get() = pulledItemCount + pushedItemCount
    val hasFailures: Boolean get() = failedStrategies.isNotEmpty()
}

@Singleton
class RecentlyPlayedSyncService @Inject constructor(

    private val strategies: Set<@JvmSuppressWildcards ProviderSyncStrategy>,
) {

    suspend fun syncOnLaunch(): ServerStatusSyncResult =
        sync(trigger = ServerStatusSyncTrigger.APP_LAUNCH)

    suspend fun sync(trigger: ServerStatusSyncTrigger): ServerStatusSyncResult {
        val force = trigger == ServerStatusSyncTrigger.HOME_PULL_TO_REFRESH ||
                    trigger == ServerStatusSyncTrigger.MANUAL_SYNC
        val launchOptimized = trigger == ServerStatusSyncTrigger.APP_LAUNCH

        Log.i(TAG, "Dispatching to ${strategies.size} strategies [trigger=$trigger]")

        var pulled = 0
        var pushed = 0
        val failed = mutableListOf<String>()

        for (strategy in strategies) {
            val result = runCatching {
                strategy.sync(force = force, launchOptimized = launchOptimized)
            }
            result.onSuccess {
                pulled += it.pulled
                pushed += it.pushed
            }.onFailure { error ->
                Log.e(TAG, "Strategy '${strategy.id}' failed", error)
                failed.add(strategy.displayName)
            }
        }

        val merged = pulled + pushed
        if (merged > 0) {
            Log.i(TAG, "Synced $merged item(s) ($pulled pulled, $pushed pushed)")
        }

        return ServerStatusSyncResult(
            attemptedStrategyCount = strategies.size,
            pulledItemCount = pulled,
            pushedItemCount = pushed,
            failedStrategies = failed,
        )
    }

    private companion object { const val TAG = "RecentlyPlayedSync" }
}
