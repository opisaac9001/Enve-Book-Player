package com.enve.core.data.sync

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SyncCapabilityTest {
    private val allFlags = setOf(
        SyncCapabilityFlag.PULL_PROGRESS,
        SyncCapabilityFlag.PUSH_PROGRESS,
        SyncCapabilityFlag.PUSH_FINISHED,
        SyncCapabilityFlag.PUSH_ANNOTATIONS,
        SyncCapabilityFlag.PULL_ANNOTATIONS,
    )

    @Test
    fun fullSupportsEveryFlag() {
        allFlags.forEach { flag ->
            assertTrue(SyncCapability.FULL.supports(flag))
        }
    }

    @Test
    fun readWriteSupportsProgressButNotAnnotations() {
        val capability = SyncCapability.READ_WRITE

        assertTrue(capability.supports(SyncCapabilityFlag.PULL_PROGRESS))
        assertTrue(capability.supports(SyncCapabilityFlag.PUSH_PROGRESS))
        assertTrue(capability.supports(SyncCapabilityFlag.PUSH_FINISHED))
        assertFalse(capability.supports(SyncCapabilityFlag.PUSH_ANNOTATIONS))
        assertFalse(capability.supports(SyncCapabilityFlag.PULL_ANNOTATIONS))
    }

    @Test
    fun noneSupportsNothing() {
        allFlags.forEach { flag ->
            assertFalse(SyncCapability.NONE.supports(flag))
        }
    }
}
