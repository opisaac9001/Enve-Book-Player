package com.enve.engine.storyalign

import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

enum class StoryAlignStatus { QUEUED, RUNNING, PAUSED, FAILED, CANCELLED, DONE }

enum class StoryAlignStage { DOWNLOAD, EPUB_PARSE, AUDIO_EXTRACT, TRANSCRIBE, ANALYZE, ALIGN, EXPORT, REGISTER }

@Serializable
enum class StoryAlignEngine { WHISPER, QUARTZNET_CTC }

enum class StoryAlignGranularity { SENTENCE, PHRASE, SEGMENT, GROUP, WORD }

@Serializable
data class StoryAlignSettings(
    val engine: StoryAlignEngine = StoryAlignEngine.WHISPER,
    val granularity: StoryAlignGranularity = StoryAlignGranularity.SENTENCE,
    val expandGranularity: Boolean = false,
    val model: String = "tiny.en",
    val language: String? = null,
    val startChapter: Int? = null,
    val endChapter: Int? = null,
    val threadCount: Int? = null,

    val allowOnBattery: Boolean = true,
)

data class StoryAlignJobUi(
    val id: String,
    val ebookTitle: String,
    val audiobookTitle: String,
    val author: String?,
    val status: StoryAlignStatus,
    val stage: StoryAlignStage,
    val stageProgress: Float,
    val overallProgress: Float,
    val errorMessage: String?,
    val outputBookId: String?,
    val createdAt: Long,
    val updatedAt: Long,
    val keptPreviousReason: String? = null,
    val hasPreviousOutput: Boolean = false,
    val alignedSentences: Int? = null,
    val totalSentences: Int? = null,
) {
    val isActive: Boolean
        get() = status == StoryAlignStatus.QUEUED || status == StoryAlignStatus.RUNNING || status == StoryAlignStatus.PAUSED
}

data class StoryAlignPairUi(
    val ebookKey: String,
    val audiobookKey: String,
    val title: String,
    val author: String?,
    val coverUrl: String?,
    val hasJob: Boolean,
)

interface StoryAlignFacade {

    val preferredEngine: StateFlow<StoryAlignEngine>

    suspend fun setPreferredEngine(engine: StoryAlignEngine)

    val jobs: Flow<List<StoryAlignJobUi>>

    val candidatePairs: Flow<List<StoryAlignPairUi>>

    suspend fun createJob(ebookKey: String, audiobookKey: String, settings: StoryAlignSettings = StoryAlignSettings()): String

    suspend fun cancelJob(jobId: String)

    suspend fun retryJob(jobId: String)

    suspend fun restorePreviousOutput(jobId: String): Boolean

    suspend fun deleteJob(jobId: String, deleteOutput: Boolean = true)
}
