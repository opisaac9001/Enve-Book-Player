package com.enve.app.storyalign

import com.enve.app.storyalign.align.AlignmentDecision
import com.enve.app.storyalign.align.AlignmentQuality
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

@Serializable
data class StoryAlignReport(
    val alignedSentences: Int,
    val totalSentences: Int,
    val acceptedQuality: AlignmentQuality? = null,
    val previousQuality: AlignmentQuality? = null,
    val lastRunAccepted: Boolean = true,
    val lastRunExplanation: String = "",
) {
    val hasPreviousOutput: Boolean get() = previousQuality != null

    fun installing(decision: AlignmentDecision, sentenceCount: Int): StoryAlignReport = StoryAlignReport(
        alignedSentences = decision.quality.unitCount,
        totalSentences = sentenceCount,
        acceptedQuality = decision.quality,
        previousQuality = acceptedQuality,
        lastRunAccepted = true,
        lastRunExplanation = decision.explanation,
    )

    fun retaining(decision: AlignmentDecision): StoryAlignReport = copy(
        lastRunAccepted = false,
        lastRunExplanation = decision.explanation,
    )

    fun restored(): StoryAlignReport = copy(
        alignedSentences = previousQuality?.unitCount ?: alignedSentences,
        acceptedQuality = previousQuality,
        previousQuality = acceptedQuality,
        lastRunAccepted = true,
        lastRunExplanation = "restored the previous read-aloud output",
    )

    companion object {
        private val json = Json { ignoreUnknownKeys = true }

        val empty = StoryAlignReport(alignedSentences = 0, totalSentences = 0)

        fun decode(raw: String?): StoryAlignReport? =
            raw?.let { runCatching { json.decodeFromString(serializer(), it) }.getOrNull() }

        fun encode(report: StoryAlignReport): String = json.encodeToString(serializer(), report)
    }
}
