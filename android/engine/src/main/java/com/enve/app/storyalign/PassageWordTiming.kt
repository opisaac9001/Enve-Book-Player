package com.enve.app.storyalign

import com.enve.app.storyalign.ctc.CtcBookMatcher

data class PassageWordTiming(val location: Int, val length: Int, val start: Double, val end: Double) {
    companion object {
        const val TOLERANCE = 0.05
        const val HOLD = 0.25

        fun validated(words: List<PassageWordTiming>, text: String, start: Double, end: Double): List<PassageWordTiming> {
            if (words.isEmpty()) return emptyList()
            val printed = CtcBookMatcher.lexicalWords(text).mapTo(HashSet()) { it.first to it.last + 1 - it.first }
            val clipped = words.filter { it.start < end }.map { if (it.end > end) it.copy(end = end) else it }
            var previous: PassageWordTiming? = null
            for (word in clipped) {
                if (!word.start.isFinite() || !word.end.isFinite() || word.end <= word.start || word.start < start - TOLERANCE ||
                    word.location to word.length !in printed) return emptyList()
                previous?.let { if (word.location < it.location + it.length || word.start < it.end - TOLERANCE) return emptyList() }
                previous = word
            }
            return clipped
        }
    }
}

data class PassageQuote(val highlight: String, val before: String, val after: String)
