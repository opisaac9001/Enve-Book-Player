package com.enve.app.storyalign

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import com.enve.app.data.offline.withDownloadCalls
import com.enve.app.playback.PlaybackState
import com.enve.app.storyalign.audio.AudioWindowDecoder
import com.enve.app.storyalign.ctc.CtcBookMatcher
import com.enve.app.storyalign.ctc.CtcSentenceMatch
import com.enve.app.storyalign.ctc.QuartzNetBookAligner
import com.enve.app.storyalign.ctc.QuartzNetModelStore
import com.enve.app.storyalign.ctc.QuartzNetSession
import com.enve.app.storyalign.ctc.ctcSha256
import com.enve.app.storyalign.epub.EpubParser
import com.enve.app.storyalign.epub.EpubZip
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.remote.ConnectionScope
import com.enve.engine.storyalign.StoryAlignGranularity
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Job
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import kotlin.math.max
import kotlin.time.TimeSource

data class PassageMapping(
    val sentence: Int,
    val href: String,
    val text: String,
    val before: String,
    val after: String,
    val progression: Double,
    val start: Double,
    val end: Double,
    val words: List<PassageWordTiming> = emptyList(),
) {
    fun wordAt(time: Double): PassageWordTiming? {
        var lower = 0
        var upper = words.size
        while (lower < upper) {
            val middle = (lower + upper) / 2
            if (words[middle].start <= time) lower = middle + 1 else upper = middle
        }
        val word = words.getOrNull(lower - 1) ?: return null
        val next = words.getOrNull(lower)
        val until = if (next != null && next.start - word.end <= PassageWordTiming.HOLD) next.start else word.end
        return word.takeIf { time < until }
    }

    fun quote(word: PassageWordTiming): PassageQuote {
        val prefix = text.substring(0, word.location)
        val suffix = text.substring(word.location + word.length)
        return PassageQuote(
            highlight = text.substring(word.location, word.location + word.length),
            before = prefix.takeLast(64).ifEmpty { before.takeLast(64) },
            after = suffix.take(64).ifEmpty { after.take(64) },
        )
    }
}

data class PassagePreparationState(
    val mapping: PassageMapping? = null,
    val word: PassageWordTiming? = null,
    val message: String = "Preparing read along…",
    val preparing: Boolean = true,
    val cannotKeepUp: Boolean = false,
    val retryable: Boolean = false,
)

class PassagePreparationException(message: String) : Exception(message)

internal class PassageBufferPolicy {
    @Volatile private var rate: Double? = null

    fun record(audioSeconds: Double, wallSeconds: Double) {
        if (audioSeconds <= 0 || wallSeconds <= 0 || !audioSeconds.isFinite() || !wallSeconds.isFinite()) return
        val measured = audioSeconds / wallSeconds
        rate = rate?.let { it * 0.6 + measured * 0.4 } ?: measured
    }

    fun ahead(speed: Double): Double {
        val playback = speed.takeIf { it.isFinite() && it > 0 } ?: 1.0
        val cushion = rate?.let { 38 / it * 3 } ?: 0.0
        return max(120.0, cushion).coerceAtMost(600.0) * playback
    }

    fun cannotKeepUp(speed: Double): Boolean = rate?.let { it < speed * 1.2 } ?: false
}

@Singleton
class PassageAlignmentService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val locations: ProfileStorageLocations,
    private val models: QuartzNetModelStore,
    private val decoder: AudioWindowDecoder,
    private val client: OkHttpClient,
) {
    private val handover = Mutex()
    private val active = java.util.concurrent.atomic.AtomicReference<Job?>(null)
    private val sessions = MutableStateFlow<Session?>(null)

    private data class Track(val index: Int, val source: String, val start: Double, val duration: Double, val revision: String? = null)
    @Serializable
    private data class Saved(val version: Int = 1, val identity: String, val windows: List<PassageWindow>)

    suspend fun follow(
        ebook: Book,
        audiobook: Book,
        epub: File,
        audioTracks: List<AudioTrack>,
        playback: () -> PlaybackState,
        isForeground: () -> Boolean,
        onUpdate: suspend (PassagePreparationState) -> Unit,
    ): Unit = coroutineScope {
        val owner = checkNotNull(currentCoroutineContext()[Job])
        try {
            handover.withLock {
                currentCoroutineContext().ensureActive()
                active.getAndSet(owner)?.takeUnless { it === owner }?.cancelAndJoin()
            }
            val execution = currentCoroutineContext()
            val originalLength = epub.length()
            val originalModified = epub.lastModified()
            val check = { execution.ensureActive() }
            val language = (audiobook.language ?: ebook.language).orEmpty().trim().lowercase().substringBefore('-').substringBefore('_')
            if (language.isNotEmpty() && language !in setOf("en", "eng", "english")) {
                throw PassagePreparationException("Live read along currently supports English books.")
            }
            onUpdate(PassagePreparationState(message = "Indexing the book text…"))
            val loaded = withContext(Dispatchers.IO + ConnectionScope.asContextElement(audiobook.connectionId)) {
                val tracks = audioTracks.sortedBy(AudioTrack::index)
                if (tracks.isEmpty() || tracks.any { it.durationMs <= 0 || it.contentUrl.isNullOrBlank() }) {
                    throw PassagePreparationException("The audiobook needs complete track durations for read along.")
                }
                var offset = 0.0
                val layout = tracks.mapIndexed { index, track ->
                    Track(index, requireNotNull(track.contentUrl), offset, track.durationMs / 1000.0)
                        .also { offset += it.duration }
                }
                val document = EpubParser.parse(EpubZip.from(epub), StoryAlignGranularity.SENTENCE)
                val chapters = document.spineOrderedManifest
                val root = File(document.opfPath).parent
                val hrefs = chapters.map { File(root, it.href).normalize().invariantSeparatorsPath }
                val matcher = CtcBookMatcher(chapters, wordTimings = true)
                withContext(Dispatchers.Main.immediate) { onUpdate(PassagePreparationState(message = "Identifying the audiobook files…")) }
                val revision = epub.ctcSha256(check)
                val audio = client.withDownloadCalls { calls -> layout.map { track ->
                    val uri = Uri.parse(track.source)
                    when (uri.scheme) {
                        null, "file" -> File(if (uri.scheme == null) track.source else requireNotNull(uri.path)).ctcSha256(check)
                        "http", "https" -> {
                            calls.execute(Request.Builder().url(track.source).head().build()).use { response ->
                                check()
                                if (!response.isSuccessful && response.code != 405 && response.code != 501) throw IOException("The audio server could not be reached (${response.code}).")
                                response.header("ETag")?.takeUnless { it.startsWith("W/") } ?: java.util.UUID.randomUUID().toString()
                            }
                        }
                        else -> java.util.UUID.randomUUID().toString()
                    }
                }
                }
                val identity = fingerprint(listOf(ebook.uniqueKey, audiobook.uniqueKey, revision, QuartzNetModelStore.MODEL_ID, FORMAT) +
                    layout.zip(audio).map { (track, revision) -> "${track.index}:${track.duration}:$revision" })
                val directory = File(locations.filesDirectory, "passage-alignment").apply { mkdirs() }
                val cache = File(directory, fingerprint(listOf(ebook.uniqueKey, audiobook.uniqueKey)) + ".json")
                val saved = try { Json.decodeFromString<Saved>(cache.readText()).takeIf { it.version == 1 && it.identity == identity } }
                    catch (_: IOException) { null } catch (_: kotlinx.serialization.SerializationException) { null }
                val validatedLayout = layout.zip(audio).map { (track, revision) ->
                    if (revision.startsWith('"')) track.copy(revision = revision) else track
                }
                Session(ebook.uniqueKey, audiobook.uniqueKey, validatedLayout, matcher, buildTimeline(validatedLayout, matcher, hrefs, saved?.windows.orEmpty()), identity, cache)
            }
            val model = models.prepare { progress ->
                withContext(Dispatchers.Main.immediate) { onUpdate(PassagePreparationState(message = "Preparing speech model: ${(progress * 100).toInt()}%")) }
            }
            val timeline = loaded.timeline
            val buffer = PassageBufferPolicy()
            val pause = MutableStateFlow<String?>(null)
            val problem = java.util.concurrent.atomic.AtomicReference<Exception?>(null)
            sessions.value = loaded
            val worker = launch(Dispatchers.IO) {
                try {
                    var engine: QuartzNetSession? = null
                    try {
                        while (isActive) {
                            if (QuartzNetBookAligner.INFERENCE_MUTEX.isLocked) {
                                engine?.close()
                                engine = null
                                pause.value = "Waiting for the other StoryAlign job to finish."
                                delay(1_000)
                                continue
                            }
                            val power = context.getSystemService(PowerManager::class.java)
                            if (android.os.StatFs(locations.filesDirectory.path).availableBytes < 256L * 1_024 * 1_024) {
                                pause.value = "Preparation paused until more storage is available."
                                delay(1_000)
                                continue
                            }
                            val urgent = timeline.hasHandoff()
                            if (!isForeground() || (!urgent && power.isPowerSaveMode) || (Build.VERSION.SDK_INT >= 29 && power.currentThermalStatus >= PowerManager.THERMAL_STATUS_MODERATE)) {
                                engine?.close()
                                engine = null
                                pause.value = "Preparation paused in the background, to save power or to cool down."
                                delay(1_000)
                                continue
                            }
                            pause.value = null
                            val state = playback()
                            val next = timeline.takeHandoffWindow()
                                ?: timeline.nextWindow(state.currentPositionMs / 1000.0, buffer.ahead(state.playbackSpeed.toDouble()))
                            if (next == null) {
                                delay(500)
                                continue
                            }
                            val track = loaded.tracks[next.first]
                            val index = next.second
                            val ownedStart = index * PassageTimeline.WINDOW
                            val start = max(0.0, ownedStart - 8)
                            val duration = minOf(ownedStart + PassageTimeline.WINDOW, track.duration) - start
                            val watch = TimeSource.Monotonic.markNow()
                            timeline.beginAnalysis(track.index, index)
                            val pcm = try { decoder.decode(track.source, audiobook.connectionId, start, duration, track.revision) }
                                catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }
                            check()
                            val matches: List<CtcSentenceMatch>? = when {
                                pcm == null -> null
                                pcm.size <= 512 -> emptyList()
                                else -> QuartzNetBookAligner.INFERENCE_MUTEX.withLock {
                                    val session = engine ?: QuartzNetSession(model).also { engine = it }
                                    val emissions = try { session.analyze(pcm) }
                                        catch (cancelled: CancellationException) { throw cancelled } catch (_: Exception) { null }
                                    check()
                                    emissions?.let {
                                        loaded.matcher.match(it, start, track.index, track.duration, check)
                                            .filter { match -> match.end > ownedStart && match.end <= ownedStart + PassageTimeline.WINDOW }
                                    }
                                }
                            }
                            check()
                            if (matches == null) {
                                timeline.fail(track.index, index)
                                delay(250)
                                continue
                            }
                            timeline.record(PassageWindow(track.index, index, matches), check)
                            val stage = File(loaded.cache.path + ".part")
                            try {
                                stage.writeText(Json.encodeToString(Saved(identity = loaded.identity, windows = timeline.windows())))
                                check()
                                check(stage.renameTo(loaded.cache)) { "Could not save prepared passages." }
                            } finally { stage.delete() }
                            buffer.record(minOf(PassageTimeline.WINDOW, track.duration - ownedStart), watch.elapsedNow().inWholeMilliseconds / 1000.0)
                            delay(250)
                        }
                    } finally { engine?.close() }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (error: Exception) { problem.set(error) }
            }
            try {
                val clock = PassageClock(android.os.SystemClock::elapsedRealtime)
                var lastMediaProbe = 0L
                while (isActive) {
                    problem.get()?.let { throw it }
                    val now = android.os.SystemClock.elapsedRealtime()
                    if (now - lastMediaProbe >= 1_000) {
                        lastMediaProbe = now
                        withContext(Dispatchers.IO) {
                            if (epub.length() != originalLength || epub.lastModified() != originalModified) {
                                throw IOException("The ebook changed. Reopen it to prepare read along.")
                            }
                            if (!loaded.filesUnchanged()) throw IOException("The audiobook changed. Reopen it to prepare read along.")
                        }
                    }
                    val state = playback()
                    val time = clock.seconds(state)
                    loaded.playhead = time
                    val update = timeline.preparationState(time, pause.value, buffer.cannotKeepUp(state.playbackSpeed.toDouble()))
                    onUpdate(update)
                    delay(if (!isForeground()) 1_000 else if (state.isPlaying && update.mapping?.words?.isNotEmpty() == true) 50 else 200)
                }
            } finally {
                worker.cancel()
                sessions.compareAndSet(loaded, null)
            }
        } finally { active.compareAndSet(owner, null) }
    }

    fun retryPreparation() {
        sessions.value?.let { it.timeline.retry(it.playhead) }
    }

    suspend fun findListeningPosition(
        ebook: Book,
        audiobook: Book,
        href: String,
        quote: String,
        before: String?,
        after: String?,
        chapterProgression: Double?,
        budgetMs: Long = HANDOFF_BUDGET_MS,
    ): PassageTextResolution {
        var latest: PassageTextResolution = PassageTextResolution.Unprepared(null)
        withTimeoutOrNull(budgetMs) {
            val timeline = sessions.filterNotNull().first { it.ebookKey == ebook.uniqueKey && it.audiobookKey == audiobook.uniqueKey }.timeline
            latest = timeline.resolveText(href, quote, before, after, chapterProgression)
            val target = (latest as? PassageTextResolution.Unprepared)?.sentence ?: return@withTimeoutOrNull
            val generation = timeline.beginHandoff(target)
            try {
                while (timeline.handoffPending(generation)) {
                    delay(150)
                    latest = timeline.resolveText(href, quote, before, after, chapterProgression)
                    if (latest is PassageTextResolution.Matched || latest is PassageTextResolution.NotSpoken) return@withTimeoutOrNull
                }
                latest = timeline.resolveText(href, quote, before, after, chapterProgression)
            } finally { timeline.endHandoff(generation) }
        }
        return latest
    }

    private class Session(
        val ebookKey: String,
        val audiobookKey: String,
        val tracks: List<Track>,
        val matcher: CtcBookMatcher,
        val timeline: PassageTimeline,
        val identity: String,
        val cache: File,
    ) {
        @Volatile var playhead = 0.0
        private val files = tracks.mapNotNull { track ->
            val uri = Uri.parse(track.source)
            val file = when (uri.scheme) {
                null -> File(track.source)
                "file" -> uri.path?.let(::File)
                else -> null
            } ?: return@mapNotNull null
            Triple(file, file.length(), file.lastModified())
        }
        fun filesUnchanged(): Boolean = files.all { (file, length, modified) -> file.isFile && file.length() == length && file.lastModified() == modified }
    }

    private fun buildTimeline(tracks: List<Track>, matcher: CtcBookMatcher, hrefs: List<String>, windows: List<PassageWindow>): PassageTimeline {
        val chapterLengths = matcher.sentences.groupBy { it.chapter }.mapValues { (_, chapter) -> chapter.sumOf { it.text.length } }
        var chapter = -1
        var offset = 0
        val sentences = matcher.sentences.mapIndexed { index, sentence ->
            if (sentence.chapter != chapter) {
                chapter = sentence.chapter
                offset = 0
            }
            PassageSentence(index, hrefs[sentence.chapter], sentence.text, offset.toDouble() / maxOf(1, chapterLengths.getValue(sentence.chapter)))
                .also { offset += sentence.text.length }
        }
        val length = maxOf(1, matcher.text.length).toDouble()
        return PassageTimeline(
            tracks.map { PassageTrackSpan(it.index, it.start, it.duration) },
            sentences,
            matcher.sentences.map { it.start / length },
            windows,
        )
    }

    private fun fingerprint(parts: List<String>): String = MessageDigest.getInstance("SHA-256")
        .digest(parts.joinToString("\u0000").toByteArray()).joinToString("") { "%02x".format(it) }

    private companion object {
        const val FORMAT = "passage-words-v1"
        const val HANDOFF_BUDGET_MS = 30_000L
    }
}
