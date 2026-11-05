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
import com.enve.app.storyalign.ctc.CtcSentenceSelector
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
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import okhttp3.Request
import kotlin.math.floor
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
)

data class PassagePreparationState(
    val mapping: PassageMapping? = null,
    val message: String = "Preparing read along…",
    val preparing: Boolean = true,
    val cannotKeepUp: Boolean = false,
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

    private data class Track(val index: Int, val source: String, val start: Double, val duration: Double, val revision: String? = null)
    @Serializable
    private data class Window(val track: Int, val index: Int, val matches: List<CtcSentenceMatch>)
    @Serializable
    private data class Saved(val version: Int = 1, val identity: String, val windows: List<Window>)

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
                val root = File(document.opfPath).parent.orEmpty()
                val hrefs = chapters.map { File(root, it.href).normalize().invariantSeparatorsPath }
                val matcher = CtcBookMatcher(chapters)
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
                val identity = fingerprint(listOf(ebook.uniqueKey, audiobook.uniqueKey, revision, QuartzNetModelStore.MODEL_ID) +
                    layout.zip(audio).map { (track, revision) -> "${track.index}:${track.duration}:$revision" })
                val directory = File(locations.filesDirectory, "passage-alignment").apply { mkdirs() }
                val cache = File(directory, fingerprint(listOf(ebook.uniqueKey, audiobook.uniqueKey)) + ".json")
                val saved = try { Json.decodeFromString<Saved>(cache.readText()).takeIf { it.version == 1 && it.identity == identity } }
                    catch (_: IOException) { null } catch (_: kotlinx.serialization.SerializationException) { null }
                val validatedLayout = layout.zip(audio).map { (track, revision) ->
                    if (revision.startsWith('"')) track.copy(revision = revision) else track
                }
                Session(validatedLayout, matcher, hrefs, identity, cache, saved?.windows.orEmpty().toMutableList())
            }
            val model = models.prepare { progress ->
                withContext(Dispatchers.Main.immediate) { onUpdate(PassagePreparationState(message = "Preparing speech model: ${(progress * 100).toInt()}%")) }
            }
            val buffer = PassageBufferPolicy()
            val progress = kotlinx.coroutines.flow.MutableStateFlow(PassagePreparationState(message = "Finding the narrated passage…"))
            val problem = java.util.concurrent.atomic.AtomicReference<Exception?>(null)
            val worker = launch(Dispatchers.IO) {
                try {
                    var engine: QuartzNetSession? = null
                    try {
                        while (isActive) {
                            if (QuartzNetBookAligner.INFERENCE_MUTEX.isLocked) {
                                engine?.close()
                                engine = null
                                progress.value = PassagePreparationState(message = "Waiting for the other StoryAlign job to finish.", preparing = false)
                                delay(1_000)
                                continue
                            }
                            val power = context.getSystemService(PowerManager::class.java)
                            if (android.os.StatFs(locations.filesDirectory.path).availableBytes < 256L * 1_024 * 1_024) {
                                progress.value = PassagePreparationState(message = "Preparation paused until more storage is available.", preparing = false)
                                delay(1_000)
                                continue
                            }
                            if (!isForeground() || power.isPowerSaveMode || (Build.VERSION.SDK_INT >= 29 && power.currentThermalStatus >= PowerManager.THERMAL_STATUS_MODERATE)) {
                                engine?.close()
                                engine = null
                                progress.value = PassagePreparationState(message = "Preparation paused in the background, to save power or to cool down.", preparing = false)
                                delay(1_000)
                                continue
                            }
                            val state = playback()
                            val position = state.currentPositionMs / 1000.0
                            val next = loaded.nextWindow(position, buffer.ahead(state.playbackSpeed.toDouble()))
                            if (next == null) {
                                progress.value = PassagePreparationState(message = "No confident match at this position.", preparing = false)
                                delay(500)
                                continue
                            }
                            progress.value = PassagePreparationState(message = "Preparing the next passage…")
                            val (track, index) = next
                            val ownedStart = index * 30.0
                            val start = max(0.0, ownedStart - 8)
                            val duration = minOf(ownedStart + 30, track.duration) - start
                            val watch = TimeSource.Monotonic.markNow()
                            val pcm = decoder.decode(track.source, audiobook.connectionId, start, duration, track.revision)
                            check()
                            val matches = if (pcm.size <= 512) emptyList() else {
                                QuartzNetBookAligner.INFERENCE_MUTEX.withLock {
                                    val active = engine ?: QuartzNetSession(model).also { engine = it }
                                    val emissions = active.analyze(pcm)
                                    check()
                                    loaded.matcher.match(emissions, start, track.index, track.duration, check)
                                        .filter { it.end > ownedStart && it.end <= ownedStart + 30 }
                                }
                            }
                            check()
                            loaded.windows.add(Window(track.index, index, matches))
                            loaded.rebuild(check)
                            val stage = File(loaded.cache.path + ".part")
                            try {
                                stage.writeText(Json.encodeToString(Saved(identity = loaded.identity, windows = loaded.windows)))
                                check()
                                check(stage.renameTo(loaded.cache)) { "Could not save prepared passages." }
                            } finally { stage.delete() }
                            buffer.record(minOf(30.0, track.duration - ownedStart), watch.elapsedNow().inWholeMilliseconds / 1000.0)
                            progress.value = PassagePreparationState(preparing = false)
                            delay(250)
                        }
                    } finally { engine?.close() }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (error: Exception) { problem.set(error) }
            }
            try {
                var lastMediaProbe = 0L
                while (isActive) {
                    problem.get()?.let { throw it }
                    if (epub.length() != originalLength || epub.lastModified() != originalModified) throw IOException("The ebook changed. Reopen it to prepare read along.")
                    val now = android.os.SystemClock.elapsedRealtime()
                    if (now - lastMediaProbe >= 1_000) {
                        lastMediaProbe = now
                        if (!withContext(Dispatchers.IO) { loaded.filesUnchanged() }) throw IOException("The audiobook changed. Reopen it to prepare read along.")
                    }
                    val state = playback()
                    val mapping = loaded.mappingAt(state.currentPositionMs / 1000.0)
                    onUpdate(PassagePreparationState(
                        mapping = mapping,
                        message = if (mapping != null) "Following audiobook" else progress.value.message,
                        preparing = mapping == null && progress.value.preparing,
                        cannotKeepUp = buffer.cannotKeepUp(state.playbackSpeed.toDouble()),
                    ))
                    delay(200)
                }
            } finally { worker.cancel() }
        } finally { active.compareAndSet(owner, null) }
    }

    private class Session(
        val tracks: List<Track>,
        val matcher: CtcBookMatcher,
        val hrefs: List<String>,
        val identity: String,
        val cache: File,
        val windows: MutableList<Window>,
    ) {
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
        private val chapters = matcher.sentences.groupBy { it.chapter }
        private val text = matcher.sentences.map { sentence ->
            val chapter = chapters.getValue(sentence.chapter)
            PassageMapping(0, hrefs[sentence.chapter], sentence.text,
                chapter.getOrNull(sentence.id - 1)?.text.orEmpty(), chapter.getOrNull(sentence.id + 1)?.text.orEmpty(),
                sentence.id.toDouble() / maxOf(1, chapter.size), 0.0, 0.0)
        }
        private val order = compareBy<CtcSentenceMatch> { it.audioIndex }.thenBy { it.start }
        @Volatile private var mappings: List<CtcSentenceMatch> = CtcSentenceSelector.select(windows.flatMap(Window::matches)) {}.sortedWith(order)

        fun rebuild(check: () -> Unit) { mappings = CtcSentenceSelector.select(windows.flatMap(Window::matches), check).sortedWith(order) }

        fun mappingAt(time: Double): PassageMapping? {
            val values = mappings
            var lower = 0
            var upper = values.size
            while (lower < upper) {
                val middle = (lower + upper) / 2
                val match = values[middle]
                val track = tracks.getOrNull(match.audioIndex) ?: return null
                if (track.start + match.start <= time) lower = middle + 1 else upper = middle
            }
            val match = values.getOrNull(lower - 1) ?: return null
            val track = tracks.getOrNull(match.audioIndex) ?: return null
            if (time >= track.start + match.end) return null
            return text.getOrNull(match.sentence)?.copy(sentence = match.sentence,
                start = track.start + match.start, end = track.start + match.end)
        }

        fun nextWindow(position: Double, ahead: Double): Pair<Track, Int>? {
            val attempted = windows.map { it.track to it.index }.toSet()
            return tracks.flatMap { track ->
                val lower = max(0.0, position - 30 - track.start)
                val upper = minOf(track.duration, position + ahead - track.start)
                if (upper <= 0 || lower >= track.duration || upper <= lower) emptyList()
                else (floor(lower / 30).toInt()..floor((upper - 0.001) / 30).toInt()).map { track to it }
            }.filter { (track, index) -> track.index to index !in attempted }
                .minByOrNull { (track, index) ->
                    val start = track.start + index * 30
                    if (position >= start && position < start + 30) -1.0 else kotlin.math.abs(start - position)
                }
        }
    }

    private fun fingerprint(parts: List<String>): String = MessageDigest.getInstance("SHA-256")
        .digest(parts.joinToString("\u0000").toByteArray()).joinToString("") { "%02x".format(it) }
}
