package com.enve.app.data.librarian

import android.util.Log
import android.content.Context
import android.net.Uri
import android.os.StatFs
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Generation
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.IOException
import java.io.RandomAccessFile
import java.util.Locale
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class LibrarianEngineManager @Inject constructor(
    @ApplicationContext private val context: Context,
    private val okHttpClient: OkHttpClient,
    private val preferenceStore: LibrarianEnginePreferenceStore,
    private val geminiNanoEngine: GeminiNanoLibrarianEngine,
    private val liteRtEngine: LiteRtLibrarianEngine,
    private val localExtractiveEngine: LocalExtractiveLibrarianEngine,
    private val remoteServerEngine: RemoteServerLibrarianEngine,
    private val remoteServerStore: LibrarianRemoteServerStore,
) {
    private val _statuses = MutableStateFlow(defaultStatuses())
    val statuses = _statuses.asStateFlow()

    val recommendedModel = RecommendedLibrarianModel(
        title = "Qwen3 0.6B",
        detail = "Apache-2.0 - ${RECOMMENDED_MODEL_SIZE_BYTES.humanBytes()}",
        sizeBytes = RECOMMENDED_MODEL_SIZE_BYTES,
    )

    suspend fun selectedPreference(): LibrarianEnginePreference = preferenceStore.load()

    suspend fun savePreference(preference: LibrarianEnginePreference) {
        preferenceStore.save(preference)
        refreshStatuses()
    }

    suspend fun refreshStatuses(): List<LibrarianEngineStatus> {
        val remote = remoteServerEngine.status()
        val gemini = geminiNanoEngine.status()
        val liteRt = liteRtEngine.status()
        val local = localExtractiveEngine.status()
        val updated = listOf(
            automaticStatus(listOf(remote, gemini, liteRt, local)),
            remote,
            gemini,
            liteRt,
            local,
        )
        _statuses.value = updated
        return updated
    }

    suspend fun downloadGeminiNano() {
        geminiNanoEngine.downloadModel()
        refreshStatuses()
    }

    suspend fun remoteServerSettings(): LibrarianRemoteServerSettings = remoteServerStore.load()

    fun hasRemoteApiKey(): Boolean = remoteServerStore.apiKey() != null

    suspend fun saveRemoteServerSettings(settings: LibrarianRemoteServerSettings) {
        remoteServerStore.save(settings)
        refreshStatuses()
    }

    fun saveRemoteApiKey(value: String?) = remoteServerStore.saveApiKey(value)

    suspend fun testRemoteServer(): List<String> = remoteServerEngine.availableModels()

    suspend fun importLiteRtModel(uri: Uri): Long = withContext(Dispatchers.IO) {
        val dir = File(context.filesDir, "enve-librarian/models").also { it.mkdirs() }
        val target = File(dir, "local-model.litertlm")
        val temp = File(dir, "local-model.litertlm.tmp")
        context.contentResolver.openInputStream(uri)?.use { input ->
            temp.outputStream().use { output -> input.copyTo(output) }
        } ?: throw EnveLibrarianException("Could not open the selected model file.")
        if (target.exists()) target.delete()
        check(temp.renameTo(target)) { "Could not save the selected model file." }
        clearLiteRtCache()
        refreshStatuses()
        target.length()
    }

    suspend fun removeLiteRtModel() = withContext(Dispatchers.IO) {
        val dir = File(context.filesDir, "enve-librarian/models")
        val target = File(dir, "local-model.litertlm")
        val temp = File(dir, "local-model.litertlm.tmp")
        if (temp.exists() && !temp.delete()) {
            throw EnveLibrarianException("Could not remove the incomplete local model file.")
        }
        if (target.exists() && !target.delete()) {
            throw EnveLibrarianException("Could not remove the installed local model.")
        }
        clearLiteRtCache()
        if (selectedPreference() == LibrarianEnginePreference.LITERT_LM) {
            preferenceStore.save(LibrarianEnginePreference.AUTOMATIC)
        }
        refreshStatuses()
    }

    fun startRecommendedModelDownload() {
        val request = OneTimeWorkRequestBuilder<LibrarianModelDownloadWorker>()
            .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        WorkManager.getInstance(context)
            .enqueueUniqueWork(MODEL_DOWNLOAD_WORK_NAME, ExistingWorkPolicy.KEEP, request)
    }

    fun cancelRecommendedModelDownload() {
        WorkManager.getInstance(context).cancelUniqueWork(MODEL_DOWNLOAD_WORK_NAME)
    }

    fun recommendedModelDownloadStates(): Flow<LibrarianModelDownloadState?> =
        WorkManager.getInstance(context)
            .getWorkInfosForUniqueWorkFlow(MODEL_DOWNLOAD_WORK_NAME)
            .map { infos ->
                val info = infos.firstOrNull() ?: return@map null
                LibrarianModelDownloadState(
                    isActive = !info.state.isFinished,
                    progress = info.progress
                        .getDouble(LibrarianModelDownloadWorker.KEY_PROGRESS, -1.0)
                        .takeIf { it >= 0.0 },
                    errorMessage = if (info.state == WorkInfo.State.FAILED) {
                        info.outputData.getString(LibrarianModelDownloadWorker.KEY_ERROR)
                            ?: "Recommended model download failed."
                    } else {
                        null
                    },
                )
            }

    suspend fun downloadRecommendedLiteRtModel(onProgress: suspend (Double) -> Unit): Long = withContext(Dispatchers.IO) {
        val dir = File(context.filesDir, "enve-librarian/models").also { it.mkdirs() }
        val target = File(dir, "local-model.litertlm")
        val temp = File(dir, "local-model.litertlm.tmp")

        if (temp.length() > RECOMMENDED_MODEL_SIZE_BYTES) temp.delete()
        if (temp.length() != RECOMMENDED_MODEL_SIZE_BYTES) {
            var resumeFrom = temp.length()
            ensureFreeDiskSpace(dir, neededBytes = RECOMMENDED_MODEL_SIZE_BYTES - resumeFrom)
            val request = Request.Builder()
                .url(RECOMMENDED_MODEL_URL)
                .header("Accept", "application/octet-stream")
                .apply { if (resumeFrom > 0L) header("Range", "bytes=$resumeFrom-") }
                .build()
            okHttpClient.newCall(request).execute().use { response ->
                if (resumeFrom > 0L && response.code != 206) {

                    temp.delete()
                    resumeFrom = 0L
                }
                if (!response.isSuccessful) {
                    throw EnveLibrarianException("Recommended model download failed (${response.code}).")
                }
                val body = response.body ?: throw EnveLibrarianException("Recommended model download returned no data.")
                val declaredBytes = body.contentLength().takeIf { it > 0L }
                val totalBytes = declaredBytes?.plus(resumeFrom) ?: RECOMMENDED_MODEL_SIZE_BYTES
                var downloadedBytes = resumeFrom
                var lastProgressBytes = downloadedBytes
                body.byteStream().use { input ->
                    RandomAccessFile(temp, "rw").use { output ->
                        output.seek(resumeFrom)
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        while (true) {
                            val count = input.read(buffer)
                            if (count == -1) break
                            output.write(buffer, 0, count)
                            downloadedBytes += count
                            if (downloadedBytes - lastProgressBytes >= MODEL_PROGRESS_STEP_BYTES) {
                                onProgress((downloadedBytes.toDouble() / totalBytes).coerceIn(0.0, 1.0))
                                lastProgressBytes = downloadedBytes
                            }
                        }
                    }
                }

                if (downloadedBytes < totalBytes) {
                    throw IOException("Recommended model download was interrupted. Enve will resume it.")
                }
            }
        }

        if (temp.length() < MIN_MODEL_BYTES) {
            temp.delete()
            throw EnveLibrarianException("Recommended model download was incomplete.")
        }
        if (target.exists()) target.delete()
        check(temp.renameTo(target)) { "Could not save the recommended model." }
        clearLiteRtCache()
        onProgress(1.0)
        refreshStatuses()
        target.length()
    }

    private fun ensureFreeDiskSpace(dir: File, neededBytes: Long) {
        val available = StatFs(dir.absolutePath).availableBytes
        if (available < neededBytes + DISK_SPACE_MARGIN_BYTES) {
            throw EnveLibrarianException(
                "Not enough free storage for the recommended model. " +
                    "Free up ${(neededBytes + DISK_SPACE_MARGIN_BYTES - available).humanBytes()} and try again."
            )
        }
    }

    suspend fun answer(
        question: String,
        book: LibrarianBookRef,
        context: BookContextResult,
    ): LibrarianAnswer {
        val preference = selectedPreference()
        val ordered = when (preference) {

            LibrarianEnginePreference.AUTOMATIC -> listOf(
                remoteServerEngine,
                liteRtEngine,
                localExtractiveEngine,
            )
            LibrarianEnginePreference.REMOTE_SERVER -> listOf(remoteServerEngine, localExtractiveEngine)
            LibrarianEnginePreference.GEMINI_NANO -> listOf(
                geminiNanoEngine,
                liteRtEngine,
                localExtractiveEngine,
            )
            LibrarianEnginePreference.LITERT_LM -> listOf(liteRtEngine, localExtractiveEngine)
            LibrarianEnginePreference.LOCAL_EXTRACTIVE -> listOf(localExtractiveEngine)
        }
        val errors = mutableListOf<String>()
        var fallbackNotice: String? = null
        for (engine in ordered) {
            val status = engine.status()
            if (!status.isUsable) {
                errors += "${status.title}: ${status.detail}"
                continue
            }
            try {
                val answer = engine.answer(question, book, context)
                return fallbackNotice?.let { notice ->
                    answer.copy(text = "$notice\n\n${answer.text}")
                } ?: answer
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                errors += "${status.title}: ${e.message ?: "failed"}"
                if (engine.preference == LibrarianEnginePreference.LITERT_LM) {
                    fallbackNotice = "The installed Local Model couldn't answer this time, so Enve answered with Basic Local."
                } else if (engine.preference == LibrarianEnginePreference.GEMINI_NANO) {
                    fallbackNotice = "Gemini Nano couldn't answer this request, so Enve is trying the next on-device model."
                } else if (engine.preference == LibrarianEnginePreference.REMOTE_SERVER) {
                    fallbackNotice = "The local server couldn't answer (${e.message ?: "request failed"}), so Enve fell back to an on-device engine."
                }
            }
        }
        throw EnveLibrarianException(errors.firstOrNull() ?: "No on-device Librarian engine is available.")
    }

    private fun automaticStatus(statuses: List<LibrarianEngineStatus>): LibrarianEngineStatus {
        val selected = statuses.firstOrNull {
            it.preference == LibrarianEnginePreference.REMOTE_SERVER && it.isUsable
        } ?: statuses.firstOrNull {
            it.preference == LibrarianEnginePreference.LITERT_LM && it.isUsable
        } ?: statuses.firstOrNull {
            it.preference == LibrarianEnginePreference.LOCAL_EXTRACTIVE && it.isUsable
        } ?: statuses.firstOrNull {
            it.preference == LibrarianEnginePreference.GEMINI_NANO && it.isUsable
        } ?: statuses.last()
        return LibrarianEngineStatus(
            preference = LibrarianEnginePreference.AUTOMATIC,
            availability = selected.availability,
            title = "Automatic",
            detail = "Uses ${selected.title} on this device.",
            isUsable = true,
        )
    }

    private fun defaultStatuses(): List<LibrarianEngineStatus> =
        LibrarianEnginePreference.entries.map {
            LibrarianEngineStatus(
                preference = it,
                availability = LibrarianEngineAvailability.UNAVAILABLE,
                title = it.title,
                detail = "Checking availability",
                isUsable = it == LibrarianEnginePreference.LOCAL_EXTRACTIVE,
            )
        }

    private fun clearLiteRtCache() {
        val cacheDir = File(context.cacheDir, "litert-lm")
        if (cacheDir.exists() && !cacheDir.deleteRecursively()) {
            throw EnveLibrarianException("Could not clear the old local model cache.")
        }
    }
}

interface LibrarianGenerationEngine {
    val preference: LibrarianEnginePreference
    val title: String
    suspend fun status(): LibrarianEngineStatus
    suspend fun answer(question: String, book: LibrarianBookRef, context: BookContextResult): LibrarianAnswer
}

@Singleton
class GeminiNanoLibrarianEngine @Inject constructor() : LibrarianGenerationEngine {
    override val preference = LibrarianEnginePreference.GEMINI_NANO
    override val title = "Gemini Nano"

    private val model by lazy { Generation.getClient() }
    private val warmedUp = AtomicBoolean(false)

    override suspend fun status(): LibrarianEngineStatus =
        when (runCatching { model.checkStatus() }.getOrNull()) {
            FeatureStatus.AVAILABLE -> status(LibrarianEngineAvailability.AVAILABLE, "Ready", true)
            FeatureStatus.DOWNLOADABLE -> status(LibrarianEngineAvailability.DOWNLOADABLE, "Available after model download", false)
            FeatureStatus.DOWNLOADING -> status(LibrarianEngineAvailability.DOWNLOADING, "Downloading model", false)
            else -> status(LibrarianEngineAvailability.UNAVAILABLE, "Not supported on this device", false)
        }

    suspend fun downloadModel() {
        if (model.checkStatus() != FeatureStatus.DOWNLOADABLE) return
        model.download().collect { download ->
            if (download is DownloadStatus.DownloadFailed) {
                throw EnveLibrarianException(download.e.message ?: "Gemini Nano download failed.")
            }
        }
        warmedUp.set(false)
    }

    override suspend fun answer(question: String, book: LibrarianBookRef, context: BookContextResult): LibrarianAnswer {
        if (model.checkStatus() != FeatureStatus.AVAILABLE) {
            throw EnveLibrarianException("Gemini Nano is not available on this device.")
        }
        try {
            ensureWarmup()
            val focusedPrompt = buildGeminiPrompt(question, book, context, broaden = false)
            val focusedText = model.generateContent(focusedPrompt)
                .candidates
                .firstOrNull()
                ?.text
                .orEmpty()
                .trim()
            val text = if (focusedText.isBlank() || focusedText.hasNoLocalContext()) {
                val broadenedPrompt = buildGeminiPrompt(question, book, context, broaden = true)
                model.generateContent(broadenedPrompt)
                    .candidates
                    .firstOrNull()
                    ?.text
                    .orEmpty()
                    .trim()
            } else {
                focusedText
            }
            if (text.isBlank() || text.hasNoLocalContext()) {
                throw EnveLibrarianException("Gemini Nano could not answer from local context.")
            }
            return LibrarianAnswer(text = text, engineTitle = title)
        } catch (e: CancellationException) {
            throw e
        } catch (e: GenAiException) {
            Log.w("GeminiNanoLibrarian", "Gemini Nano failed with code=${e.errorCode}: ${e.message}")
            throw mapGeminiException(e)
        }
    }

    private suspend fun ensureWarmup() {
        if (warmedUp.get()) return
        try {
            model.warmup()
            warmedUp.set(true)
        } catch (e: GenAiException) {
            Log.w("GeminiNanoLibrarian", "Gemini Nano warmup failed with code=${e.errorCode}: ${e.message}")
            throw mapGeminiException(e)
        }
    }

    private fun status(
        availability: LibrarianEngineAvailability,
        detail: String,
        usable: Boolean,
    ): LibrarianEngineStatus =
        LibrarianEngineStatus(
            preference = preference,
            availability = availability,
            title = title,
            detail = detail,
            isUsable = usable,
        )
}

private fun mapGeminiException(error: GenAiException): EnveLibrarianException =
    EnveLibrarianException(
        when (error.errorCode) {
            GenAiException.ErrorCode.AICORE_INCOMPATIBLE ->
                "Gemini Nano needs Android AI Core on this device."
            GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED ->
                "Gemini Nano can only run while Enve is open on screen."
            GenAiException.ErrorCode.BUSY ->
                "Gemini Nano is busy right now. Please wait a moment and try again."
            GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE ->
                "Gemini Nano needs a newer Android system update on this device."
            GenAiException.ErrorCode.NOT_AVAILABLE ->
                "Gemini Nano is not ready on this device yet. If it was just installed, give Android AI Core a little time and try again."
            GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE ->
                "Gemini Nano needs more free storage before it can run."
            GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED ->
                "Gemini Nano hit Android's battery quota for this app. Try again later."
            GenAiException.ErrorCode.REQUEST_TOO_LARGE ->
                "This Gemini Nano request was too large for the on-device model."
            GenAiException.ErrorCode.REQUEST_TOO_SMALL ->
                "This Gemini Nano request was too small to answer."
            GenAiException.ErrorCode.REQUEST_PROCESSING_ERROR ->
                "Gemini Nano rejected this request before generation."
            GenAiException.ErrorCode.RESPONSE_GENERATION_ERROR ->
                "Gemini Nano could not generate a response for this request."
            GenAiException.ErrorCode.RESPONSE_PROCESSING_ERROR ->
                "Gemini Nano generated a response Android would not return."
            else ->
                error.message ?: "Gemini Nano failed on this device."
        }
    )

private fun String.hasNoLocalContext(): Boolean {
    val value = lowercase()
    return value.contains("no local context") ||
        value.contains("not enough local context") ||
        value.contains("there is no local context") ||
        value.contains("does not have local context") ||
        value.contains("doesn't have local context") ||
        value.contains("does not have local context available") ||
        value.contains("local context does not show it yet")
}

@Singleton
class LiteRtLibrarianEngine @Inject constructor(
    @ApplicationContext private val context: Context,
) : LibrarianGenerationEngine {
    override val preference = LibrarianEnginePreference.LITERT_LM
    override val title = "Local Model"
    private val processClient = LiteRtLibrarianProcessClient(context)

    private val modelFile: File
        get() = File(context.filesDir, "enve-librarian/models/local-model.litertlm")

    override suspend fun status(): LibrarianEngineStatus = withContext(Dispatchers.IO) {
        if (modelFile.isFile && modelFile.length() > 0L) {
            LibrarianEngineStatus(
                preference = preference,
                availability = LibrarianEngineAvailability.AVAILABLE,
                title = title,
                detail = "Ready (${modelFile.length().humanBytes()})",
                isUsable = true,
            )
        } else {
            LibrarianEngineStatus(
                preference = preference,
                availability = LibrarianEngineAvailability.MODEL_MISSING,
                title = title,
                detail = "Import a .litertlm model to use this engine",
                isUsable = false,
            )
        }
    }

    override suspend fun answer(question: String, book: LibrarianBookRef, context: BookContextResult): LibrarianAnswer {
        if (!modelFile.isFile) throw EnveLibrarianException("Import a .litertlm model before using Local Model.")
        val cacheDir = File(this.context.cacheDir, "litert-lm").also { it.mkdirs() }
        val text = processClient.generate(
            modelPath = modelFile.absolutePath,
            cacheDir = cacheDir.absolutePath,
            prompt = buildLlmPrompt(question, book, context),
        )
        return LibrarianAnswer(text = text, engineTitle = title)
    }
}

const val LIBRARIAN_SYSTEM_INSTRUCTION =
    "You are Enve Librarian, a friendly older male librarian who enjoys helping people and speaks in a warm, calm way. " +
        "Answer only from the provided ebook context. " +
        "Respect the spoiler boundary. If the context does not contain the answer, say that the local context does not show it yet. " +
        "Keep the answer concise and helpful. " +
        "Return only the final answer. " +
        "Do not reveal reasoning, chain-of-thought, or internal notes. " +
        "Do not emit <think> tags."

private fun buildGeminiPrompt(
    question: String,
    book: LibrarianBookRef,
    context: BookContextResult,
    broaden: Boolean,
): String =
    """
    $LIBRARIAN_SYSTEM_INSTRUCTION

    ## instruction
    Answer from the excerpt below only.
    If the excerpt supports a partial answer, give the partial answer instead of refusing.
    Do not say that there is no local context if the excerpt names the people, events, or details needed to answer.
    If the excerpt truly does not show the answer, respond exactly with: The local context does not show that yet.

    ## book
    Book: ${book.title}
    Author: ${book.author.orEmpty()}
    Scope: ${context.scope.promptName}

    ## question
    Question:
    $question

    ## ebook_excerpt
    Ebook excerpt:
    ${context.geminiExcerpt(question, broaden)}
    """.trimIndent()

private fun buildLlmPrompt(question: String, book: LibrarianBookRef, context: BookContextResult): String =
    """
    $LIBRARIAN_SYSTEM_INSTRUCTION

    Book: ${book.title}
    Author: ${book.author.orEmpty()}
    Scope: ${context.scope.promptName}

    Relevant ebook context:
    ${context.liteRtExcerpt(question)}

    Question:
    $question /no_think
    """.trimIndent()

private fun BookContextResult.geminiExcerpt(question: String, broaden: Boolean): String {
    val compact = text.compactWhitespace()
    if (compact.isBlank()) return compact

    val limit = if (broaden) GEMINI_BROAD_CONTEXT_CHARS else GEMINI_FOCUSED_CONTEXT_CHARS
    if (compact.length <= limit) return compact

    val sentences = compact.split(Regex("(?<=[.!?])\\s+"))
        .map { it.trim() }
        .filter { it.isNotBlank() }
    if (sentences.isEmpty()) return compact.takeLast(limit)

    val terms = questionTerms(question)
    val matched = if (terms.isEmpty()) emptyList() else sentences.filter { sentence ->
        terms.any { sentence.contains(it, ignoreCase = true) }
    }

    val focused = when {
        broaden -> (matched.takeLast(12) + sentences.takeLast(8)).distinct()
        matched.isNotEmpty() -> matched.takeLast(8)
        else -> emptyList()
    }.joinToString(" ")
        .takeIf { it.length >= GEMINI_MIN_RELEVANT_CHARS }
    if (focused != null) return focused.take(limit)

    return compact.takeLast(limit)
}

private fun BookContextResult.liteRtExcerpt(question: String): String {
    val compact = text.compactWhitespace()
    if (compact.length <= LITERT_PROMPT_CONTEXT_CHARS) return compact

    val terms = questionTerms(question)
    if (terms.isNotEmpty()) {
        val relevant = compact.split(Regex("(?<=[.!?])\\s+"))
            .map { it.trim() }
            .filter { sentence -> terms.any { sentence.contains(it, ignoreCase = true) } }
            .takeLast(8)
            .joinToString(" ")
            .takeIf { it.length >= 240 }
        if (relevant != null) return relevant.take(LITERT_PROMPT_CONTEXT_CHARS)
    }

    return compact.takeLast(LITERT_PROMPT_CONTEXT_CHARS)
}

private fun String.compactWhitespace(): String =
    replace(Regex("\\s+"), " ").trim()

private fun questionTerms(question: String): Set<String> =
    question.lowercase(Locale.US)
        .split(Regex("[^a-z0-9']+"))
        .filter { it.length >= 4 && it !in llmStopWords }
        .toSet()

private fun Long.humanBytes(): String {
    val mb = this / (1024.0 * 1024.0)
    val gb = mb / 1024.0
    return if (gb >= 1.0) "%.1f GB".format(gb) else "%.0f MB".format(mb)
}

private const val RECOMMENDED_MODEL_URL =
    "https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm"
private const val RECOMMENDED_MODEL_SIZE_BYTES = 614_236_160L
internal const val MODEL_DOWNLOAD_WORK_NAME = "librarian-model-download"
private const val DISK_SPACE_MARGIN_BYTES = 200L * 1024L * 1024L
private const val MODEL_PROGRESS_STEP_BYTES = 2L * 1024L * 1024L
private const val MIN_MODEL_BYTES = 100L * 1024L * 1024L

private const val LITERT_PROMPT_CONTEXT_CHARS = 3_200
private const val GEMINI_FOCUSED_CONTEXT_CHARS = 3_200
private const val GEMINI_BROAD_CONTEXT_CHARS = 6_000
private const val GEMINI_MIN_RELEVANT_CHARS = 240

private val llmStopWords = setOf(
    "about",
    "after",
    "again",
    "book",
    "catch",
    "chapter",
    "details",
    "from",
    "important",
    "involved",
    "local",
    "part",
    "previous",
    "summary",
    "there",
    "this",
    "what",
    "when",
    "where",
    "which",
    "with",
)
