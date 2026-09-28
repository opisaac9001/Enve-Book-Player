package com.enve.app.viewmodel

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderPositionBaselineTest {
    private val opened = """{"href":"text/chapter1.xhtml","locations":{"progression":0.4,"totalProgression":0.12}}"""
    private val nextPage = """{"href":"text/chapter1.xhtml","locations":{"progression":0.45,"totalProgression":0.13}}"""

    @Test
    fun closingOnTheRestoredPageIsNotAChange() {
        val baseline = ReaderPositionBaseline()

        baseline.confirm(opened)

        assertTrue(baseline.isUnchanged(opened))
    }

    @Test
    fun aPageTurnIsAChangeUntilItIsSaved() {
        val baseline = ReaderPositionBaseline()
        baseline.confirm(opened)

        assertFalse(baseline.isUnchanged(nextPage))

        baseline.confirm(nextPage)
        assertTrue(baseline.isUnchanged(nextPage))
        assertFalse(baseline.isUnchanged(opened))
    }

    @Test
    fun anUnknownPositionIsAlwaysAChange() {
        val baseline = ReaderPositionBaseline()

        assertFalse(baseline.isUnchanged(opened))
        assertFalse(baseline.isUnchanged(null))

        baseline.confirm(opened)
        baseline.confirm(null)
        assertTrue(baseline.isUnchanged(opened))

        baseline.reset()
        assertFalse(baseline.isUnchanged(opened))
    }
}
