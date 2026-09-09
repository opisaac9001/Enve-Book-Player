package com.enve.core.data.sync

data class ProviderSyncResult(
    val pulled: Int,
    val pushed: Int,
    val failedBackends: List<String> = emptyList(),
) {
    companion object {
        val ZERO = ProviderSyncResult(pulled = 0, pushed = 0)
    }
}

interface ProviderSyncStrategy {

    val id: String

    val displayName: String

    suspend fun sync(force: Boolean, launchOptimized: Boolean): ProviderSyncResult
}
