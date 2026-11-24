package com.enve.engine.podcasts

import com.enve.core.data.model.Book
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

object PodcastRoutineLimits {
    const val MAX_ROUTINES = 50
    const val MAX_RULES = 30
    const val MAX_NAME_LENGTH = 60
    const val DEFAULT_NAME = "Untitled routine"
    val episodeCounts = 1..10
}

@Serializable
sealed interface PodcastRoutinePick {
    val maximumEpisodes: Int

    @Serializable
    @SerialName("newest_unplayed")
    data object NewestUnplayed : PodcastRoutinePick {
        override val maximumEpisodes: Int get() = 1
    }

    @Serializable
    @SerialName("next_unplayed")
    data class NextUnplayed(val count: Int) : PodcastRoutinePick {
        override val maximumEpisodes: Int get() = count
    }
}

@Serializable
data class PodcastRoutineRule(
    val id: String,
    val feedUrl: String,
    val showTitle: String,
    val pick: PodcastRoutinePick = PodcastRoutinePick.NewestUnplayed,
)

@Serializable
data class PodcastRoutine(
    val id: String,
    val name: String,
    val rules: List<PodcastRoutineRule>,
)

data class PodcastRoutineRuleOutcome(
    val ruleId: String,
    val showTitle: String,
    val episodes: List<Book>,
    val note: String?,
)

data class PodcastRoutineRun(
    val routineId: String,
    val routineName: String,
    val outcomes: List<PodcastRoutineRuleOutcome>,
    val queuedCount: Int,
    val wasOffline: Boolean,
) {
    val didPlay: Boolean get() = queuedCount > 0
    val explanations: List<PodcastRoutineRuleOutcome> get() = outcomes.filter { it.note != null }
}
