package com.enve.engine.matching

import com.enve.engine.library.LibraryMetadataMatch

object BatchMatchPolicy {
    fun shouldAutoApply(matches: List<LibraryMetadataMatch>, thresholdPercent: Int): Boolean {
        val ranked = matches.sortedByDescending(LibraryMetadataMatch::confidence)
        val best = ranked.firstOrNull() ?: return false
        return best.confidence >= thresholdPercent / 100.0 &&
            (ranked.getOrNull(1)?.let { best.confidence - it.confidence >= 0.05 } ?: true)
    }
}
