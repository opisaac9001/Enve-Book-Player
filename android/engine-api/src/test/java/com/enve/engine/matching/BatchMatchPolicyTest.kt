package com.enve.engine.matching

import com.enve.engine.library.LibraryMetadataMatch
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BatchMatchPolicyTest {
    @Test
    fun requiresThresholdAndClearLead() {
        assertTrue(BatchMatchPolicy.shouldAutoApply(listOf(match("a", 0.96)), 95))
        assertFalse(BatchMatchPolicy.shouldAutoApply(listOf(match("a", 0.94)), 95))
        assertFalse(BatchMatchPolicy.shouldAutoApply(listOf(match("a", 0.98), match("b", 0.95)), 95))
        assertTrue(BatchMatchPolicy.shouldAutoApply(listOf(match("b", 0.85), match("a", 0.96)), 95))
    }

    private fun match(id: String, confidence: Double) = LibraryMetadataMatch(
        id = id, externalId = id, sourceName = "Test", title = "Novel",
        confidence = confidence, matchReason = "Test",
    )
}
