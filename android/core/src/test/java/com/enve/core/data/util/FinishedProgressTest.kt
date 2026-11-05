package com.enve.core.data.util

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FinishedProgressTest {

    @Test
    fun doubleProgressAtExactlyThresholdCountsAsFinished() {
        assertTrue(0.99.reachesFinishedThreshold())
        assertTrue((99.0 / 100.0).reachesFinishedThreshold())
        assertTrue(1.0.reachesFinishedThreshold())
        assertFalse(0.98.reachesFinishedThreshold())
        assertFalse(0.9899.reachesFinishedThreshold())
    }
}
