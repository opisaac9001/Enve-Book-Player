package com.enve.app.data.sync

import com.enve.core.data.sync.SyncSnapshot

object ProgressResolutionPolicy {
    enum class Decision { NONE, PULL, PUSH, CONFLICT }

    private const val ZERO_EPSILON = 0.001f
    private const val EQUAL_TOLERANCE = 0.005f
    private const val SKEW_MS = 1_000L

    fun resolve(
        localPercentage: Float,
        localUpdatedAt: Long?,
        remote: SyncSnapshot,
    ): Decision {
        val localPct = localPercentage.coerceIn(0f, 1f)
        val remotePct = remote.percentage.coerceIn(0f, 1f)

        if (localPct <= ZERO_EPSILON && remotePct <= ZERO_EPSILON) return Decision.NONE
        if (localPct <= ZERO_EPSILON) return Decision.PULL
        if (remotePct <= ZERO_EPSILON) return Decision.PUSH
        if (kotlin.math.abs(remotePct - localPct) < EQUAL_TOLERANCE) return Decision.NONE

        val remoteUpdatedAt = remote.updatedAt
        if (remoteUpdatedAt == null || localUpdatedAt == null) {
            return if (remotePct > localPct) Decision.PULL else Decision.PUSH
        }

        val localIsNewer = localUpdatedAt > remoteUpdatedAt + SKEW_MS
        val remoteIsNewer = remoteUpdatedAt > localUpdatedAt + SKEW_MS

        if (remoteIsNewer && remotePct >= localPct) return Decision.PULL
        if (localIsNewer && localPct >= remotePct) return Decision.PUSH

        if (remoteIsNewer || localIsNewer) return Decision.CONFLICT

        return if (remotePct > localPct) Decision.PULL else Decision.PUSH
    }

    fun bestSnapshot(snapshots: List<SyncSnapshot>): SyncSnapshot? {
        if (snapshots.isEmpty()) return null
        val timestamped = snapshots.filter { it.updatedAt != null }
        return if (timestamped.isNotEmpty()) {
            timestamped.maxWithOrNull(compareBy<SyncSnapshot> { it.updatedAt!! }.thenBy { it.percentage })
        } else {
            snapshots.maxByOrNull { it.percentage }
        }
    }
}
