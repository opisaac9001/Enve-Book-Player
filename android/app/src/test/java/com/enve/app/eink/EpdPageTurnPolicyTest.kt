package com.enve.app.eink

import org.junit.Assert.assertEquals
import org.junit.Test

class EpdPageTurnPolicyTest {
    @Test
    fun offNeverRefreshesOrChangesCadence() {
        val decision = EpdPageTurnPolicy.decide(
            strength = 0,
            fullRefreshEveryN = 6,
            turnsSinceFullRefresh = 4,
            isFullPageBoundary = true,
        )

        assertEquals(EpdPageTurnAction.NONE, decision.action)
        assertEquals(4, decision.turnsSinceFullRefresh)
    }

    @Test
    fun lightOnlyRefreshesOnFullPageBoundaries() {
        assertEquals(
            EpdPageTurnAction.NONE,
            EpdPageTurnPolicy.decide(
                strength = 1,
                fullRefreshEveryN = 6,
                turnsSinceFullRefresh = 2,
                isFullPageBoundary = false,
            ).action,
        )

        val boundary = EpdPageTurnPolicy.decide(
            strength = 1,
            fullRefreshEveryN = 6,
            turnsSinceFullRefresh = 2,
            isFullPageBoundary = true,
        )

        assertEquals(EpdPageTurnAction.FULL, boundary.action)
        assertEquals(0, boundary.turnsSinceFullRefresh)
    }

    @Test
    fun standardPartialsUntilCadenceFullRefresh() {
        val partial = EpdPageTurnPolicy.decide(
            strength = 2,
            fullRefreshEveryN = 3,
            turnsSinceFullRefresh = 1,
            isFullPageBoundary = false,
        )

        assertEquals(EpdPageTurnAction.PARTIAL, partial.action)
        assertEquals(2, partial.turnsSinceFullRefresh)

        val full = EpdPageTurnPolicy.decide(
            strength = 2,
            fullRefreshEveryN = 3,
            turnsSinceFullRefresh = 2,
            isFullPageBoundary = false,
        )

        assertEquals(EpdPageTurnAction.FULL, full.action)
        assertEquals(0, full.turnsSinceFullRefresh)
    }

    @Test
    fun strongAlwaysFullRefreshes() {
        val decision = EpdPageTurnPolicy.decide(
            strength = 3,
            fullRefreshEveryN = 6,
            turnsSinceFullRefresh = 5,
            isFullPageBoundary = false,
        )

        assertEquals(EpdPageTurnAction.FULL, decision.action)
        assertEquals(0, decision.turnsSinceFullRefresh)
    }
}
