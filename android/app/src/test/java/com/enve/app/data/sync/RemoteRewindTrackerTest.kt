package com.enve.app.data.sync

import org.junit.Assert.assertEquals
import org.junit.Test

class RemoteRewindTrackerTest {

    private val preciseLocator =
        """{"href":"chapter3.xhtml","locations":{"cfi":"epubcfi(/6/4!/4/2/1:8)","totalProgression":0.32}}"""
    private val percentageOnlyLocator = """{"locations":{"totalProgression":0.32}}"""

    private fun scope(
        source: String = "Living Room Server",
        connectionId: String = "connection-a",
    ) = RemoteProgressScope(
        bookId = "book-1",
        domainKey = "ebook",
        connectionId = connectionId,
        source = source,
    )

    private fun observation(
        percentage: Float,
        at: Long,
        locatorJson: String? = preciseLocator,
        positionMs: Long? = null,
    ) = RemoteProgressObservation(
        percentage = percentage,
        positionMs = positionMs,
        locatorJson = locatorJson,
        observedAt = at,
    )

    @Test
    fun remoteAheadOfLocalIsNotARewind() {
        val tracker = RemoteRewindTracker()
        assertEquals(
            RemoteRewindVerdict.NOT_REWIND,
            tracker.assess(scope(), observation(0.8f, at = 2_000L), localPercentage = 0.6f, nowMs = 2_000L),
        )
    }

    @Test
    fun firstBackwardObservationIsUnconfirmed() {
        val tracker = RemoteRewindTracker()
        assertEquals(
            RemoteRewindVerdict.UNCONFIRMED,
            tracker.assess(scope(), observation(0.3f, at = 2_000L), localPercentage = 0.6f, nowMs = 2_000L),
        )
    }

    @Test
    fun repeatedPollingOfTheSameObservationNeverConfirms() {
        val tracker = RemoteRewindTracker()
        val scope = scope()
        val stale = observation(0.3f, at = 2_000L)
        repeat(5) {
            assertEquals(
                RemoteRewindVerdict.UNCONFIRMED,
                tracker.assess(scope, stale, localPercentage = 0.6f, nowMs = 2_000L),
            )
        }
    }

    @Test
    fun newerTimestampAloneDoesNotConfirm() {
        val tracker = RemoteRewindTracker()
        val scope = scope()
        tracker.assess(scope, observation(0.3f, at = 2_000L), localPercentage = 0.6f, nowMs = 2_000L)
        assertEquals(
            RemoteRewindVerdict.UNCONFIRMED,
            tracker.assess(scope, observation(0.3f, at = 5_000L), localPercentage = 0.6f, nowMs = 5_000L),
        )
    }

    @Test
    fun advancingObservationFromTheSameSourceConfirms() {
        val tracker = RemoteRewindTracker()
        val scope = scope()
        tracker.assess(scope, observation(0.3f, at = 2_000L), localPercentage = 0.6f, nowMs = 2_000L)
        assertEquals(
            RemoteRewindVerdict.CONFIRMED,
            tracker.assess(scope, observation(0.35f, at = 5_000L), localPercentage = 0.6f, nowMs = 5_000L),
        )
    }

    @Test
    fun confirmedVerdictIsStableWhenTheSameSnapshotIsAssessedTwice() {
        val tracker = RemoteRewindTracker()
        val scope = scope()
        tracker.assess(scope, observation(0.3f, at = 2_000L), localPercentage = 0.6f, nowMs = 2_000L)
        val advance = observation(0.35f, at = 5_000L)
        assertEquals(
            RemoteRewindVerdict.CONFIRMED,
            tracker.assess(scope, advance, localPercentage = 0.6f, nowMs = 5_000L),
        )
        assertEquals(
            RemoteRewindVerdict.CONFIRMED,
            tracker.assess(scope, advance, localPercentage = 0.6f, nowMs = 5_100L),
        )
    }

    @Test
    fun advanceWithoutAPrecisePositionDoesNotConfirm() {
        val tracker = RemoteRewindTracker()
        val scope = scope()
        tracker.assess(
            scope,
            observation(0.3f, at = 2_000L, locatorJson = percentageOnlyLocator),
            localPercentage = 0.6f,
            nowMs = 2_000L,
        )
        assertEquals(
            RemoteRewindVerdict.UNCONFIRMED,
            tracker.assess(
                scope,
                observation(0.35f, at = 5_000L, locatorJson = percentageOnlyLocator),
                localPercentage = 0.6f,
                nowMs = 5_000L,
            ),
        )
    }

    @Test
    fun audioPositionCountsAsAPrecisePosition() {
        val tracker = RemoteRewindTracker()
        val scope = scope().copy(domainKey = "audiobook")
        tracker.assess(
            scope,
            observation(0.3f, at = 2_000L, locatorJson = null, positionMs = 3_000_000L),
            localPercentage = 0.6f,
            nowMs = 2_000L,
        )
        assertEquals(
            RemoteRewindVerdict.CONFIRMED,
            tracker.assess(
                scope,
                observation(0.35f, at = 5_000L, locatorJson = null, positionMs = 3_500_000L),
                localPercentage = 0.6f,
                nowMs = 5_000L,
            ),
        )
    }

    @Test
    fun nearZeroResetDoesNotConfirmARewind() {
        val tracker = RemoteRewindTracker()
        val scope = scope()
        tracker.assess(scope, observation(0.001f, at = 2_000L), localPercentage = 0.6f, nowMs = 2_000L)
        assertEquals(
            RemoteRewindVerdict.UNCONFIRMED,
            tracker.assess(scope, observation(0.008f, at = 5_000L), localPercentage = 0.6f, nowMs = 5_000L),
        )
    }

    @Test
    fun advanceFromADifferentSourceDoesNotConfirm() {
        val tracker = RemoteRewindTracker()
        tracker.assess(
            scope(source = "Living Room Server"),
            observation(0.3f, at = 2_000L),
            localPercentage = 0.6f,
            nowMs = 2_000L,
        )
        assertEquals(
            RemoteRewindVerdict.UNCONFIRMED,
            tracker.assess(
                scope(source = "KOReader Hub"),
                observation(0.35f, at = 5_000L),
                localPercentage = 0.6f,
                nowMs = 5_000L,
            ),
        )
    }

    @Test
    fun advanceFromADifferentConnectionDoesNotConfirm() {
        val tracker = RemoteRewindTracker()
        tracker.assess(
            scope(connectionId = "connection-a"),
            observation(0.3f, at = 2_000L),
            localPercentage = 0.6f,
            nowMs = 2_000L,
        )
        assertEquals(
            RemoteRewindVerdict.UNCONFIRMED,
            tracker.assess(
                scope(connectionId = "connection-b"),
                observation(0.35f, at = 5_000L),
                localPercentage = 0.6f,
                nowMs = 5_000L,
            ),
        )
    }

    @Test
    fun remoteReplayingOurOwnWriteIsAnEcho() {
        val tracker = RemoteRewindTracker()
        val scope = scope()
        tracker.recordOutboundWrite(
            key = scope.writeKey,
            percentage = 0.3f,
            positionMs = null,
            locatorJson = preciseLocator,
            atMs = 1_000L,
        )
        assertEquals(
            RemoteRewindVerdict.ECHO,
            tracker.assess(scope, observation(0.3f, at = 2_000L), localPercentage = 0.6f, nowMs = 2_000L),
        )
    }

    @Test
    fun ourOwnWriteCannotConfirmAPendingRewind() {
        val tracker = RemoteRewindTracker()
        val scope = scope()
        assertEquals(
            RemoteRewindVerdict.UNCONFIRMED,
            tracker.assess(scope, observation(0.3f, at = 2_000L), localPercentage = 0.6f, nowMs = 2_000L),
        )

        tracker.recordOutboundWrite(
            key = scope.writeKey,
            percentage = 0.6f,
            positionMs = null,
            locatorJson = null,
            atMs = 3_000L,
        )
        assertEquals(
            RemoteRewindVerdict.ECHO,
            tracker.assess(
                scope,
                observation(0.6f, at = 4_000L, locatorJson = null),
                localPercentage = 0.65f,
                nowMs = 4_000L,
            ),
        )
        assertEquals(
            RemoteRewindVerdict.CONFIRMED,
            tracker.assess(scope, observation(0.35f, at = 5_000L), localPercentage = 0.65f, nowMs = 5_000L),
        )
    }

    @Test
    fun keepingLocalSuppressesFurtherPromptsForThatSource() {
        val tracker = RemoteRewindTracker()
        val scope = scope()
        tracker.assess(scope, observation(0.3f, at = 2_000L), localPercentage = 0.6f, nowMs = 2_000L)
        tracker.recordUserResolution(scope, acceptedRemote = false, nowMs = 3_000L)

        assertEquals(
            RemoteRewindVerdict.DISMISSED,
            tracker.assess(scope, observation(0.35f, at = 5_000L), localPercentage = 0.6f, nowMs = 5_000L),
        )
        assertEquals(
            RemoteRewindVerdict.DISMISSED,
            tracker.assess(scope, observation(0.4f, at = 9_000L), localPercentage = 0.6f, nowMs = 9_000L),
        )
    }

    @Test
    fun dismissalClearsOnceTheSourceCatchesUp() {
        val tracker = RemoteRewindTracker()
        val scope = scope()
        tracker.assess(scope, observation(0.3f, at = 2_000L), localPercentage = 0.6f, nowMs = 2_000L)
        tracker.recordUserResolution(scope, acceptedRemote = false, nowMs = 3_000L)
        assertEquals(
            RemoteRewindVerdict.DISMISSED,
            tracker.assess(scope, observation(0.35f, at = 5_000L), localPercentage = 0.6f, nowMs = 5_000L),
        )

        assertEquals(
            RemoteRewindVerdict.NOT_REWIND,
            tracker.assess(scope, observation(0.7f, at = 9_000L), localPercentage = 0.6f, nowMs = 9_000L),
        )
        assertEquals(
            RemoteRewindVerdict.UNCONFIRMED,
            tracker.assess(scope, observation(0.3f, at = 12_000L), localPercentage = 0.6f, nowMs = 12_000L),
        )
    }

    @Test
    fun acceptingRemoteDropsThePendingCandidate() {
        val tracker = RemoteRewindTracker()
        val scope = scope()
        tracker.assess(scope, observation(0.3f, at = 2_000L), localPercentage = 0.6f, nowMs = 2_000L)
        tracker.recordUserResolution(scope, acceptedRemote = true, nowMs = 3_000L)

        assertEquals(
            RemoteRewindVerdict.UNCONFIRMED,
            tracker.assess(scope, observation(0.35f, at = 5_000L), localPercentage = 0.6f, nowMs = 5_000L),
        )
    }

    @Test
    fun observationWithoutATimestampNeverBecomesACandidate() {
        val tracker = RemoteRewindTracker()
        val scope = scope()
        val undated = RemoteProgressObservation(
            percentage = 0.3f,
            positionMs = null,
            locatorJson = preciseLocator,
            observedAt = null,
        )
        assertEquals(
            RemoteRewindVerdict.UNCONFIRMED,
            tracker.assess(scope, undated, localPercentage = 0.6f, nowMs = 2_000L),
        )
        assertEquals(
            RemoteRewindVerdict.UNCONFIRMED,
            tracker.assess(scope, observation(0.35f, at = 5_000L), localPercentage = 0.6f, nowMs = 5_000L),
        )
    }
}
