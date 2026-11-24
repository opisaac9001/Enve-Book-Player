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

    @Test
    fun oneMinuteAheadInALongAudiobookPulls() {
        val remote = SyncSnapshot(percentage = 0.0503f, positionMs = 3_660_000L,
            source = "Audiobookshelf", updatedAt = 10_000L)
        assertEquals(ProgressResolutionPolicy.Decision.PULL,
            ProgressResolutionPolicy.resolve(0.05f, 1_000L, remote, localPositionMs = 3_600_000L))
    }

    @Test
    fun audioPositionWinsOverStaleServerPercentage() {
        val remote = SyncSnapshot(percentage = 0.05f, positionMs = 1_800_000L,
            source = "Audiobookshelf", updatedAt = 10_000L)
        assertEquals(ProgressResolutionPolicy.Decision.PULL,
            ProgressResolutionPolicy.resolve(0.05f, 1_000L, remote, localPositionMs = 900_000L))
    }

    @Test
    fun newerRemoteAudioRewindStillConflicts() {
        val remote = SyncSnapshot(percentage = 0.05f, positionMs = 3_540_000L,
            source = "Audiobookshelf", updatedAt = 10_000L)
        assertEquals(ProgressResolutionPolicy.Decision.CONFLICT,
            ProgressResolutionPolicy.resolve(0.05f, 1_000L, remote, localPositionMs = 3_600_000L))
    }

    @Test
    fun subsecondAudioDifferenceStaysPut() {
        val remote = SyncSnapshot(percentage = 0.05f, positionMs = 3_600_500L,
            source = "Audiobookshelf", updatedAt = 10_000L)
        assertEquals(ProgressResolutionPolicy.Decision.NONE,
            ProgressResolutionPolicy.resolve(0.05f, 1_000L, remote, localPositionMs = 3_600_000L))
    }

    private fun fragmentLocator(id: String) =
        """{"href":"OEBPS/text/ch1.xhtml","type":"application/xhtml+xml","locations":{"fragments":["$id"]}}"""

    private fun checkpointLocator(id: String) =
        """{"schemaVersion":1,"href":"OEBPS/text/ch1.xhtml","domRange":{"start":{"cssSelector":"#$id","textNodeIndex":0,"charOffset":0}},"totalProgression":0.09}"""

    @Test
    fun newerRemoteSentenceWinsInsideTheTolerance() {
        val remote = SyncSnapshot(percentage = 0.093f, locatorJson = fragmentLocator("s141"), source = "Audiobookshelf", updatedAt = 10_000L)
        val decision = ProgressResolutionPolicy.resolve(0.090f, 1_000L, remote, checkpointLocator("s116"))
        assertEquals(ProgressResolutionPolicy.Decision.PULL, decision)
    }

    @Test
    fun newerLocalSentenceIsPushedInsideTheTolerance() {
        val remote = SyncSnapshot(percentage = 0.090f, locatorJson = fragmentLocator("s116"), source = "Audiobookshelf", updatedAt = 1_000L)
        val decision = ProgressResolutionPolicy.resolve(0.093f, 10_000L, remote, checkpointLocator("s141"))
        assertEquals(ProgressResolutionPolicy.Decision.PUSH, decision)
    }

    @Test
    fun sameSentenceInEitherFormatStaysPut() {
        val remote = SyncSnapshot(percentage = 0.093f, locatorJson = fragmentLocator("s141"), source = "Audiobookshelf", updatedAt = 10_000L)
        val decision = ProgressResolutionPolicy.resolve(0.090f, 1_000L, remote, checkpointLocator("s141"))
        assertEquals(ProgressResolutionPolicy.Decision.NONE, decision)
    }
}
