package com.enve.app.storyalign

import com.enve.app.storyalign.ctc.CtcBookMatcher
import java.util.Locale

data class PassageSentence(val index: Int, val href: String, val text: String, val chapterProgression: Double)

sealed interface PassageTextResolution {
    data class Matched(val mapping: PassageMapping, val seekSeconds: Double) : PassageTextResolution
    data class NotSpoken(val sentence: PassageSentence) : PassageTextResolution
    data object Ambiguous : PassageTextResolution
    data class Unprepared(val sentence: PassageSentence?) : PassageTextResolution
}

internal object PassageTextResolver {
    const val PAUSE_TOLERANCE = 2.0
    private const val PROGRESSION_MARGIN = 0.05
    private const val SEEK_LEAD = 0.16
    private val SEPARATORS = Regex("[^\\p{L}\\p{N}]+")

    sealed interface Target {
        data class Found(val sentence: PassageSentence) : Target
        data object Ambiguous : Target
        data object Missing : Target
    }

    fun target(sentences: List<PassageSentence>, href: String, quote: String, before: String?, after: String?, progression: Double?): Target {
        val query = normalized(quote)
        if (query.length < 3) return Target.Ambiguous
        val chapter = sentences.filter { hrefMatches(it.href, href) }
        val texts = chapter.map { normalized(it.text) }
        val probe = query.take(32)
        val candidates = chapter.indices.filter { texts[it].length >= 3 && (texts[it].contains(probe) || query.startsWith(texts[it].take(32))) }
            .ifEmpty { chapter.indices.filter { it < chapter.lastIndex && "${texts[it]} ${texts[it + 1]}".contains(probe) } }
        if (candidates.isEmpty()) return Target.Missing
        if (candidates.size == 1) return Target.Found(chapter[candidates.single()])
        val lead = normalized(before.orEmpty()).takeLast(24).trim()
        val trail = normalized(after.orEmpty()).take(24).trim()
        val contextual = candidates.filter { index ->
            val around = (maxOf(0, index - 2)..minOf(chapter.lastIndex, index + 2)).joinToString(" ") { texts[it] }
            (lead.isNotEmpty() && around.contains("$lead ${query.take(16)}")) || (trail.isNotEmpty() && around.contains("${query.takeLast(16)} $trail"))
        }
        val pool = contextual.ifEmpty { candidates }.map { chapter[it] }
        if (pool.size == 1) return Target.Found(pool.single())
        progression ?: return Target.Ambiguous
        val ranked = pool.sortedBy { kotlin.math.abs(it.chapterProgression - progression) }
        val best = kotlin.math.abs(ranked[0].chapterProgression - progression)
        val runnerUp = kotlin.math.abs(ranked[1].chapterProgression - progression)
        return if (runnerUp - best > PROGRESSION_MARGIN) Target.Found(ranked[0]) else Target.Ambiguous
    }

    fun resolve(target: PassageSentence, quote: String, mapping: PassageMapping?, previous: PassageMapping?, next: PassageMapping?): PassageTextResolution =
        when {
            mapping != null -> PassageTextResolution.Matched(mapping, seekSeconds(mapping, quote))
            previous != null && next != null && next.start - previous.end <= PAUSE_TOLERANCE + 1 -> PassageTextResolution.NotSpoken(target)
            else -> PassageTextResolution.Unprepared(target)
        }

    fun seekSeconds(mapping: PassageMapping, quote: String): Double {
        if (mapping.words.isEmpty()) return mapping.start
        val printed = CtcBookMatcher.lexicalWords(mapping.text)
        val tokens = printed.flatMapIndexed { word, range ->
            normalized(mapping.text.substring(range.first, range.last + 1)).split(' ').map { it to word }
        }
        val query = normalized(quote).split(' ').filter(String::isNotEmpty).take(4)
        if (query.isEmpty()) return mapping.start
        val required = minOf(query.size, 2)
        val starts = tokens.indices.filter { at ->
            val available = minOf(query.size, tokens.size - at)
            available >= required && (0 until available).all { tokens[at + it].first == query[it] }
        }
        val word = starts.singleOrNull()?.let { tokens[it].second }?.takeIf { it > 0 } ?: return mapping.start
        val timing = mapping.words.lastOrNull { it.location <= printed[word].first } ?: return mapping.start
        return maxOf(mapping.start, timing.start - SEEK_LEAD)
    }

    fun normalized(text: String): String =
        text.lowercase(Locale.ROOT).replace('’', '\'').split(SEPARATORS).filter(String::isNotEmpty).joinToString(" ")

    fun hrefMatches(lhs: String, rhs: String): Boolean {
        fun normalize(href: String): String {
            val path = href.substringBefore('#')
            val decoded = try { java.net.URLDecoder.decode(path.replace("+", "%2B"), "UTF-8") } catch (_: IllegalArgumentException) { path }
            return decoded.trim('/').lowercase(Locale.ROOT)
        }
        val a = normalize(lhs)
        val b = normalize(rhs)
        if (a.isEmpty() || b.isEmpty()) return false
        return a == b || a.endsWith("/$b") || b.endsWith("/$a")
    }
}
