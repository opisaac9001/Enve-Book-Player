package com.enve.app.data.reader

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EpubBridgeCheckpointStoreTest {
    @Test
    fun currentLeaseAndRevisionMayCommit() {
        assertTrue(
            checkpointWriteIsCurrent(
                currentWriterEpoch = 8,
                currentRevision = 14,
                leaseWriterEpoch = 8,
                expectedRevision = 14,
            ),
        )
    }

    @Test
    fun olderDelayedWriteInSameLeaseIsRejected() {
        assertFalse(
            checkpointWriteIsCurrent(
                currentWriterEpoch = 8,
                currentRevision = 15,
                leaseWriterEpoch = 8,
                expectedRevision = 14,
            ),
        )
    }

    @Test
    fun writeFromSupersededLeaseIsRejected() {
        assertFalse(
            checkpointWriteIsCurrent(
                currentWriterEpoch = 9,
                currentRevision = 14,
                leaseWriterEpoch = 8,
                expectedRevision = 14,
            ),
        )
    }
}
