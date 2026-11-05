package com.enve.app.storyalign

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PassageBufferPolicyTest {
    @Test fun playbackSpeedScalesTheListeningCushion() {
        val policy = PassageBufferPolicy()
        assertEquals(120.0, policy.ahead(1.0), 0.001)
        assertEquals(240.0, policy.ahead(2.0), 0.001)
        policy.record(30.0, 2.0)
        assertEquals(240.0, policy.ahead(2.0), 0.001)
        assertFalse(policy.cannotKeepUp(2.0))
    }

    @Test fun slowAnalysisExpandsButBoundsTheBuffer() {
        val policy = PassageBufferPolicy()
        policy.record(30.0, 90.0)
        assertEquals(342.0, policy.ahead(1.0), 0.001)
        assertTrue(policy.cannotKeepUp(1.0))
        repeat(10) { policy.record(30.0, 3_000.0) }
        assertEquals(1_200.0, policy.ahead(2.0), 0.001)
    }

    @Test fun invalidMeasurementsDoNotPoisonLaterRequests() {
        val policy = PassageBufferPolicy()
        policy.record(Double.NaN, 1.0)
        policy.record(30.0, 0.0)
        policy.record(0.0, 1.0)
        assertEquals(120.0, policy.ahead(Double.NaN), 0.001)
        policy.record(30.0, 1.0)
        assertFalse(policy.cannotKeepUp(2.0))
    }
}
