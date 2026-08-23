package com.enve.app.data.sync

import com.enve.core.data.sync.SyncSnapshot
import org.junit.Assert.assertEquals
import org.junit.Test

class ProgressResolutionPolicyTest {
    @Test
    fun staleFartherRemoteConflictsWithNewerLocal() {

        val remote = SyncSnapshot(percentage = 0.72f, source = "Grimmory", updatedAt = 1_000L)

        val decision = ProgressResolutionPolicy.resolve(
            localPercentage = 0.40f,
            localUpdatedAt = 10_000L,
            remote = remote,
        )

        assertEquals(ProgressResolutionPolicy.Decision.CONFLICT, decision)
    }

    @Test
    fun newerRemotePullsWhenItAdvanced() {
        val remote = SyncSnapshot(percentage = 0.72f, source = "Grimmory", updatedAt = 10_000L)

        val decision = ProgressResolutionPolicy.resolve(
            localPercentage = 0.40f,
            localUpdatedAt = 1_000L,
            remote = remote,
        )

        assertEquals(ProgressResolutionPolicy.Decision.PULL, decision)
    }

    @Test
    fun zeroRemotePushesStartedLocal() {
        val remote = SyncSnapshot(percentage = 0f, source = "Grimmory", updatedAt = 10_000L)

        val decision = ProgressResolutionPolicy.resolve(
            localPercentage = 0.40f,
            localUpdatedAt = 1_000L,
            remote = remote,
        )

        assertEquals(ProgressResolutionPolicy.Decision.PUSH, decision)
    }

    @Test
    fun newerServerButFurtherBackConflicts() {

        val remote = SyncSnapshot(percentage = 0.20f, source = "Grimmory", updatedAt = 10_000L)

        val decision = ProgressResolutionPolicy.resolve(
            localPercentage = 0.75f,
            localUpdatedAt = 1_000L,
            remote = remote,
        )

        assertEquals(ProgressResolutionPolicy.Decision.CONFLICT, decision)
    }

    @Test
    fun newerServerSlightlyAheadPulls() {

        val remote = SyncSnapshot(percentage = 0.90f, source = "Grimmory", updatedAt = 10_000L)

        val decision = ProgressResolutionPolicy.resolve(
            localPercentage = 0.30f,
            localUpdatedAt = 1_000L,
            remote = remote,
        )

        assertEquals(ProgressResolutionPolicy.Decision.PULL, decision)
    }

    @Test
    fun bestSnapshotPrefersFreshTimestampOverFarthestProgress() {
        val staleFarther = SyncSnapshot(
            percentage = 0.80f,
            source = "Grimmory",
            updatedAt = 1_000L,
        )
        val freshLower = SyncSnapshot(
            percentage = 0.45f,
            source = "KOReader",
            updatedAt = 10_000L,
        )

        assertEquals(freshLower, ProgressResolutionPolicy.bestSnapshot(listOf(staleFarther, freshLower)))
    }
}
