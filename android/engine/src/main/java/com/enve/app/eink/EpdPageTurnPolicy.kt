package com.enve.app.eink

enum class EpdPageTurnAction {
    NONE,
    PARTIAL,
    FULL,
}

data class EpdPageTurnDecision(
    val action: EpdPageTurnAction,
    val turnsSinceFullRefresh: Int,
)

object EpdPageTurnPolicy {
    fun decide(
        strength: Int,
        fullRefreshEveryN: Int,
        turnsSinceFullRefresh: Int,
        isFullPageBoundary: Boolean,
    ): EpdPageTurnDecision {
        val current = turnsSinceFullRefresh.coerceAtLeast(0)
        return when (strength.coerceIn(0, 3)) {
            0 -> EpdPageTurnDecision(EpdPageTurnAction.NONE, current)
            1 -> if (isFullPageBoundary) {
                EpdPageTurnDecision(EpdPageTurnAction.FULL, 0)
            } else {
                EpdPageTurnDecision(EpdPageTurnAction.NONE, current)
            }
            2 -> {
                val next = current + 1
                if (isFullPageBoundary || next >= fullRefreshEveryN.coerceAtLeast(1)) {
                    EpdPageTurnDecision(EpdPageTurnAction.FULL, 0)
                } else {
                    EpdPageTurnDecision(EpdPageTurnAction.PARTIAL, next)
                }
            }
            else -> EpdPageTurnDecision(EpdPageTurnAction.FULL, 0)
        }
    }
}
