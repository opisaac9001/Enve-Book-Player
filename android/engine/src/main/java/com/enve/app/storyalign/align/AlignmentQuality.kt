package com.enve.app.storyalign.align

import kotlinx.serialization.Serializable
import kotlin.math.abs
import kotlin.math.ln

enum class AlignmentDefect { TOO_FEW_UNITS, MALFORMED_UNITS, NOT_MONOTONIC, DEGENERATE_SPAN }

enum class AlignmentRejection { INVALID_CANDIDATE, INFERIOR_CANDIDATE }

@Serializable
data class AlignmentQuality(
    val unitCount: Int,
    val coverage: Double,
    val largestGap: Double,
    val monotonicity: Double,
    val timingConsistency: Double,
    val purity: Double,
    val confidence: Double?,
    val defects: List<AlignmentDefect>,
) {
    val isUsable: Boolean get() = defects.isEmpty()
}

@Serializable
data class AlignmentDecision(
    val accepted: Boolean,
    val explanation: String,
    val quality: AlignmentQuality,
    val rejection: AlignmentRejection? = null,
)

object AlignmentQualityEvaluator {

    class Assessment(val units: List<AlignedSentence>, val quality: AlignmentQuality)

    fun assess(chapters: List<AlignedChapter>, audioDurationsByIndex: Map<Int, Double>): Assessment {
        val offsets = fileOffsets(audioDurationsByIndex)
        val totalDuration = audioDurationsByIndex.values.sum()
        val totalSentences = chapters.sumOf { it.manifestItem.xhtmlSentences.size }

        var submitted = 0
        var sentenceBase = 0
        val usable = ArrayList<TimedUnit>()
        for (chapter in chapters) {
            for (sentence in chapter.alignedSentences) {
                submitted++
                val fileIndex = sentence.sentenceRange.audioFile.index
                val fileDuration = audioDurationsByIndex[fileIndex] ?: continue
                if (!wellFormed(sentence, fileDuration)) continue
                val offset = offsets.getValue(fileIndex)
                usable.add(
                    TimedUnit(
                        globalSentenceId = sentenceBase + sentence.sentenceId,
                        start = offset + sentence.sentenceRange.start,
                        end = offset + sentence.sentenceRange.end,
                        wordCount = sentence.xhtmlSentenceWords.size,
                        directMatch = sentence.matchType?.let { it in DIRECT_MATCHES } == true,
                        sentence = sentence,
                    ),
                )
            }
            sentenceBase += chapter.manifestItem.xhtmlSentences.size
        }

        val chain = longestConsistentRun(usable)
        val purity = if (submitted == 0) 0.0 else usable.size.toDouble() / submitted
        val monotonicity = if (usable.isEmpty()) 0.0 else chain.size.toDouble() / usable.size
        val alignedSeconds = chain.sumOf { it.end - it.start }
        val audioCoverage =
            if (totalDuration <= 0.0) 0.0 else (alignedSeconds / totalDuration).coerceIn(0.0, 1.0)
        val textCoverage =
            if (totalSentences == 0) 0.0 else chain.size.toDouble() / totalSentences
        val coverage = minOf(audioCoverage, textCoverage)

        val defects = buildList {
            if (chain.size < MINIMUM_UNITS) add(AlignmentDefect.TOO_FEW_UNITS)
            if (purity < MAJORITY) add(AlignmentDefect.MALFORMED_UNITS)
            if (monotonicity < MAJORITY) add(AlignmentDefect.NOT_MONOTONIC)
            if (chain.size >= MINIMUM_UNITS && coverage < MINIMUM_SPAN) {
                add(AlignmentDefect.DEGENERATE_SPAN)
            }
        }

        return Assessment(
            units = chain.map { it.sentence },
            quality = AlignmentQuality(
                unitCount = chain.size,
                coverage = coverage,
                largestGap = maxOf(timeGap(chain, totalDuration), textGap(chain, totalSentences)),
                monotonicity = monotonicity,
                timingConsistency = timingConsistency(chain),
                purity = purity,
                confidence = if (chain.isEmpty()) {
                    null
                } else {
                    chain.count { it.directMatch }.toDouble() / chain.size
                },
                defects = defects,
            ),
        )
    }

    fun decide(candidate: Assessment, incumbent: AlignmentQuality?): AlignmentDecision {
        if (!candidate.quality.isUsable) {
            return AlignmentDecision(
                accepted = false,
                explanation = "the new alignment is ${describe(candidate.quality.defects)}",
                quality = candidate.quality,
                rejection = AlignmentRejection.INVALID_CANDIDATE,
            )
        }
        val accepted = AlignmentDecision(
            accepted = true,
            explanation = "aligned ${candidate.quality.unitCount} sentences",
            quality = candidate.quality,
        )
        if (incumbent == null || !incumbent.isUsable) return accepted

        val measurements = comparisons(candidate.quality, incumbent)
        val regressions = measurements.filter { it.regressed }
        if (regressions.size <= measurements.count { it.improved }) return accepted
        return AlignmentDecision(
            accepted = false,
            explanation = "the new alignment lost ${regressions.joinToString(" and ") { it.name }}",
            quality = candidate.quality,
            rejection = AlignmentRejection.INFERIOR_CANDIDATE,
        )
    }

    private class TimedUnit(
        val globalSentenceId: Int,
        val start: Double,
        val end: Double,
        val wordCount: Int,
        val directMatch: Boolean,
        val sentence: AlignedSentence,
    )

    private class Comparison(
        val name: String,
        candidate: Double,
        incumbent: Double,
        margin: Double,
    ) {
        val regressed = incumbent - candidate > margin
        val improved = candidate - incumbent > margin
    }

    private fun comparisons(candidate: AlignmentQuality, incumbent: AlignmentQuality): List<Comparison> {
        val candidateConfidence = candidate.confidence
        val incumbentConfidence = incumbent.confidence
        return listOfNotNull(
            Comparison(
                "aligned sentences",
                candidate.unitCount.toDouble(),
                incumbent.unitCount.toDouble(),
                incumbent.unitCount * UNIT_COUNT_MARGIN,
            ),
            Comparison("coverage", candidate.coverage, incumbent.coverage, MARGIN),
            Comparison("continuity", 1.0 - candidate.largestGap, 1.0 - incumbent.largestGap, MARGIN),
            Comparison("ordering", candidate.monotonicity, incumbent.monotonicity, MARGIN),
            Comparison(
                "timing consistency",
                candidate.timingConsistency,
                incumbent.timingConsistency,
                MARGIN,
            ),
            Comparison("well-formed sentences", candidate.purity, incumbent.purity, MARGIN),
            if (candidateConfidence != null && incumbentConfidence != null) {
                Comparison("direct matches", candidateConfidence, incumbentConfidence, MARGIN)
            } else {
                null
            },
        )
    }

    private fun describe(defects: List<AlignmentDefect>): String =
        defects.joinToString(" and ") {
            when (it) {
                AlignmentDefect.TOO_FEW_UNITS -> "too short"
                AlignmentDefect.MALFORMED_UNITS -> "mostly malformed"
                AlignmentDefect.NOT_MONOTONIC -> "out of order"
                AlignmentDefect.DEGENERATE_SPAN -> "confined to one spot in the book"
            }
        }

    private fun wellFormed(sentence: AlignedSentence, fileDuration: Double): Boolean {
        val range = sentence.sentenceRange
        return range.start.isFinite() && range.end.isFinite() &&
            range.start >= 0.0 &&
            range.end > range.start &&
            range.end <= fileDuration + TIMESTAMP_SLACK_SECONDS &&
            sentence.xhtmlSentence.isNotBlank()
    }

    private fun fileOffsets(durations: Map<Int, Double>): Map<Int, Double> {
        var running = 0.0
        return durations.keys.sorted().associateWith { index ->
            val offset = running
            running += durations.getValue(index)
            offset
        }
    }

    private fun longestConsistentRun(units: List<TimedUnit>): List<TimedUnit> {
        if (units.isEmpty()) return emptyList()
        val tails = ArrayList<Int>()
        val predecessor = IntArray(units.size)
        for (index in units.indices) {
            val start = units[index].start
            var lo = 0
            var hi = tails.size
            while (lo < hi) {
                val mid = (lo + hi) / 2
                if (units[tails[mid]].start < start) lo = mid + 1 else hi = mid
            }
            predecessor[index] = if (lo > 0) tails[lo - 1] else -1
            if (lo == tails.size) tails.add(index) else tails[lo] = index
        }
        val run = ArrayList<TimedUnit>(tails.size)
        var cursor = tails.last()
        while (cursor >= 0) {
            run.add(units[cursor])
            cursor = predecessor[cursor]
        }
        run.reverse()
        return run
    }

    private fun timeGap(chain: List<TimedUnit>, totalDuration: Double): Double {
        if (chain.isEmpty() || totalDuration <= 0.0) return 1.0
        var gap = chain.first().start
        for (index in 1 until chain.size) {
            gap = maxOf(gap, chain[index].start - chain[index - 1].end)
        }
        gap = maxOf(gap, totalDuration - chain.last().end)
        return (gap / totalDuration).coerceIn(0.0, 1.0)
    }

    private fun textGap(chain: List<TimedUnit>, totalSentences: Int): Double {
        if (totalSentences == 0) return 1.0
        val aligned = BooleanArray(totalSentences)
        for (unit in chain) {
            if (unit.globalSentenceId in 0 until totalSentences) aligned[unit.globalSentenceId] = true
        }
        var longest = 0
        var run = 0
        for (flag in aligned) {
            if (flag) {
                run = 0
            } else {
                run++
                if (run > longest) longest = run
            }
        }
        return longest.toDouble() / totalSentences
    }

    private fun timingConsistency(chain: List<TimedUnit>): Double {
        if (chain.size < 3) return 1.0
        val totalSeconds = chain.sumOf { it.end - it.start }
        val totalWords = chain.sumOf { it.wordCount }
        if (totalSeconds <= 0.0 || totalWords == 0) return 0.0
        val overallRate = totalSeconds / totalWords

        val deviations = ArrayList<Double>(chain.size)
        for (unit in chain) {
            val seconds = unit.end - unit.start
            if (unit.wordCount == 0 || seconds <= 0.0) continue
            deviations.add(abs(ln(seconds / unit.wordCount / overallRate)))
        }
        val middle = median(deviations) ?: return 1.0
        return 1.0 / (1.0 + middle)
    }

    private fun median(values: List<Double>): Double? {
        if (values.isEmpty()) return null
        val sorted = values.sorted()
        val middle = sorted.size / 2
        return if (sorted.size % 2 == 0) (sorted[middle - 1] + sorted[middle]) / 2 else sorted[middle]
    }

    private val DIRECT_MATCHES = setOf(
        SentenceMatchType.EXACT,
        SentenceMatchType.TRIMMED_LEADING,
        SentenceMatchType.IGNORING_ENDS_PUNCTUATION,
        SentenceMatchType.IGNORING_ALL_PUNCTUATION,
    )

    private const val MAJORITY = 0.5
    private const val MINIMUM_UNITS = 2
    private const val MINIMUM_SPAN = 0.02
    private const val MARGIN = 0.10
    private const val UNIT_COUNT_MARGIN = 0.25
    private const val TIMESTAMP_SLACK_SECONDS = 1.0
}
