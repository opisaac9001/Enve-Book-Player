package com.enve.bookorbit.sync

import com.enve.bookorbit.bookOrbitEpubLocator

import org.junit.Assert.assertEquals
import org.junit.Test

class BookOrbitProgressResolverTest {
    @Test
    fun newerExactPositionWinsEvenForSamePercentageBackwardAndZeroMoves() {
        val earlier = bookOrbitEpubLocator("epubcfi(/6/8!/4/2:10)", 0.5f)
        val later = bookOrbitEpubLocator("epubcfi(/6/8!/4/2:20)", 0.5f)
        for (percentage in listOf(0.5f, 0.499f, 0.2f, 0f)) {
            assertEquals(BookOrbitProgressDecision.PULL,
                BookOrbitProgressResolver.resolve(0.5f, 1000L, percentage, 1100L, earlier, later))
            assertEquals(BookOrbitProgressDecision.PUSH,
                BookOrbitProgressResolver.resolve(percentage, 1100L, 0.5f, 1000L, later, earlier))
        }
    }

    @Test
    fun equalOrUnknownTimestampsDoNotInventCfiOrdering() {
        val earlier = bookOrbitEpubLocator("epubcfi(/6/8!/4/2:10)", 0.5f)
        val later = bookOrbitEpubLocator("epubcfi(/6/8!/4/2:20)", 0.5f)
        for (time in listOf(null, 1000L)) {
            assertEquals(BookOrbitProgressDecision.NONE,
                BookOrbitProgressResolver.resolve(0.5f, time, 0.5f, 1000L, earlier, later))
        }
        assertEquals(BookOrbitProgressDecision.NONE,
            BookOrbitProgressResolver.resolve(0.5f, 1000L, 0.5f, 2000L, later, later))
    }

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
