package com.enve.bookorbit.sync

import org.junit.Assert.assertEquals
import org.junit.Test

class BookOrbitProgressResolverTest {
    @Test
    fun remoteNewerAndAheadPulls() {
        assertEquals(
            BookOrbitProgressDecision.PULL,
            BookOrbitProgressResolver.resolve(0.25f, 1_000L, 0.5f, 3_000L),
        )
    }

    @Test
    fun localNewerAndAheadPushes() {
        assertEquals(
            BookOrbitProgressDecision.PUSH,
            BookOrbitProgressResolver.resolve(0.5f, 3_000L, 0.25f, 1_000L),
        )
    }

    @Test
    fun newerSideBehindIsConflict() {
        assertEquals(
            BookOrbitProgressDecision.CONFLICT,
            BookOrbitProgressResolver.resolve(0.75f, 1_000L, 0.5f, 3_000L),
        )
    }

    @Test
    fun equalProgressDoesNothing() {
        assertEquals(
            BookOrbitProgressDecision.NONE,
            BookOrbitProgressResolver.resolve(0.5f, 1_000L, 0.502f, 5_000L),
        )
    }
}
