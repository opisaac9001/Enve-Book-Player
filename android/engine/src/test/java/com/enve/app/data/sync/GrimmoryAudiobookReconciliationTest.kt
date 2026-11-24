package com.enve.app.data.sync

import com.enve.core.data.sync.SyncSnapshot
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GrimmoryAudiobookReconciliationTest {
    private val remoteFinishedAt = 1_700_000_000_000L
    private val finished = SyncSnapshot(percentage = 1f, source = "GRIMMORY", updatedAt = remoteFinishedAt, finished = true)

    @Test
    fun newerLocalRereadAgainstOlderRemoteCompletionIsKept() {
        val decision = ProgressResolutionPolicy.resolve(
            localPercentage = 0.05f,
            localUpdatedAt = remoteFinishedAt + 3_600_000L,
            remote = finished,
        )

        assertEquals(ProgressResolutionPolicy.Decision.CONFLICT, decision)
        assertFalse(appliesRemoteAudiobookProgress(finished, decision))
    }

    @Test
    fun newerRemoteCompletionIsApplied() {
        val decision = ProgressResolutionPolicy.resolve(
            localPercentage = 0.8f,
            localUpdatedAt = remoteFinishedAt - 3_600_000L,
            remote = finished,
        )

        assertEquals(ProgressResolutionPolicy.Decision.PULL, decision)
        assertTrue(appliesRemoteAudiobookProgress(finished, decision))
    }

    @Test
    fun matchingCompletionStillMarksFinished() {
        val decision = ProgressResolutionPolicy.resolve(
            localPercentage = 0.998f,
            localUpdatedAt = remoteFinishedAt,
            remote = finished,
        )

        assertEquals(ProgressResolutionPolicy.Decision.NONE, decision)
        assertTrue(appliesRemoteAudiobookProgress(finished, decision))
    }

    @Test
    fun localPushAndUnfinishedNoneAreNotApplied() {
        val partial = finished.copy(percentage = 0.4f, finished = false)

        assertFalse(appliesRemoteAudiobookProgress(finished, ProgressResolutionPolicy.Decision.PUSH))
        assertFalse(appliesRemoteAudiobookProgress(partial, ProgressResolutionPolicy.Decision.NONE))
        assertFalse(appliesRemoteAudiobookProgress(partial, ProgressResolutionPolicy.Decision.CONFLICT))
        assertTrue(appliesRemoteAudiobookProgress(partial, ProgressResolutionPolicy.Decision.PULL))
    }
}
