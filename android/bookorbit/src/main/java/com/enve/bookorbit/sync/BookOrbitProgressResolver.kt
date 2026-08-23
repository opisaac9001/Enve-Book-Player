package com.enve.bookorbit.sync

internal enum class BookOrbitProgressDecision { NONE, PULL, PUSH, CONFLICT }

internal object BookOrbitProgressResolver {
    private const val ZERO_EPSILON = 0.001f
    private const val EQUAL_TOLERANCE = 0.005f
    private const val SKEW_MS = 1_000L

    fun resolve(
        localPercentage: Float,
        localUpdatedAt: Long?,
        remotePercentage: Float,
        remoteUpdatedAt: Long?,
    ): BookOrbitProgressDecision {
        val local = localPercentage.coerceIn(0f, 1f)
        val remote = remotePercentage.coerceIn(0f, 1f)

        if (local <= ZERO_EPSILON && remote <= ZERO_EPSILON) return BookOrbitProgressDecision.NONE
        if (local <= ZERO_EPSILON) return BookOrbitProgressDecision.PULL
        if (remote <= ZERO_EPSILON) return BookOrbitProgressDecision.PUSH
        if (kotlin.math.abs(remote - local) < EQUAL_TOLERANCE) return BookOrbitProgressDecision.NONE

        if (localUpdatedAt == null || remoteUpdatedAt == null) {
            return if (remote > local) BookOrbitProgressDecision.PULL else BookOrbitProgressDecision.PUSH
        }

        val localIsNewer = localUpdatedAt > remoteUpdatedAt + SKEW_MS
        val remoteIsNewer = remoteUpdatedAt > localUpdatedAt + SKEW_MS
        if (remoteIsNewer && remote >= local) return BookOrbitProgressDecision.PULL
        if (localIsNewer && local >= remote) return BookOrbitProgressDecision.PUSH
        if (remoteIsNewer || localIsNewer) return BookOrbitProgressDecision.CONFLICT
        return if (remote > local) BookOrbitProgressDecision.PULL else BookOrbitProgressDecision.PUSH
    }
}
