package com.enve.core.data.vocab

import java.text.BreakIterator

object SentenceExtractor {

    fun enclosingSentence(before: String, word: String, after: String): String {
        val combined = (before + word + after)
        val trimmed = combined.trim()
        if (trimmed.isEmpty()) return word.trim()

        val wordIndex = trimmed.indexOf(word.trim()).takeIf { it >= 0 }
            ?: return trimmed
        val mid = wordIndex + word.trim().length / 2

        val it = BreakIterator.getSentenceInstance()
        it.setText(trimmed)
        var start = it.first()
        var end = it.next()
        while (end != BreakIterator.DONE) {
            if (mid in start until end) {
                val sentence = trimmed.substring(start, end).trim()
                return sentence.ifEmpty { trimmed }
            }
            start = end
            end = it.next()
        }
        return trimmed
    }
}
