package com.enve.app.readium

import android.content.Context
import android.util.Log
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import com.enve.app.playback.cumulativeTrackOffsets
import com.enve.core.data.model.AudioTrack
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.abs
import kotlin.math.roundToLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.Url
import org.readium.r2.shared.util.getOrElse

internal fun resolveReadAloudAbsoluteAudioPosition(
    externalWindowStartMs: Long?,
    playerPositionMs: Long,
    overlayChapterStartMs: Long?,
    overlayElapsedBeforeClipMs: Long,
    clipBeginMs: Long,
    clipDurationMs: Long,
): Long? {
    if (externalWindowStartMs != null) return externalWindowStartMs + playerPositionMs
    val chapterStart = overlayChapterStartMs ?: return null
    val withinClip = (playerPositionMs - clipBeginMs).coerceAtLeast(0L)
    return chapterStart + overlayElapsedBeforeClipMs + if (clipDurationMs > 0L) {
        withinClip.coerceAtMost(clipDurationMs)
    } else {
        withinClip
    }
}

internal fun storytellerReadAloudAudioStem(raw: String): String? {
    val key = audioResourceKey(raw)
    val stem = key.substringBeforeLast('.', key)
    val match = Regex("^(\\d{5})-00001$").matchEntire(stem) ?: return null
    val chapterIndex = match.groupValues[1].toIntOrNull() ?: return null
    return "00001-${(chapterIndex + 1).toString().padStart(5, '0')}"
}

internal fun resolveExternalAudioWindowIndex(
    audioHref: String,
    exactKeyToIndex: Map<String, Int>,
    readAloudStemToIndex: Map<String, Int>,
): Int? {
    val key = audioResourceKey(audioHref)
    val stem = key.substringBeforeLast('.', key)
    return readAloudStemToIndex[stem] ?: exactKeyToIndex[key]
}

internal fun audioResourceKey(raw: String): String {
    val decoded = runCatching { java.net.URLDecoder.decode(raw, "UTF-8") }.getOrDefault(raw)
    return decoded.substringBefore('?').substringBefore('#').substringAfterLast('/').lowercase()
}

internal fun externalAudioChapterSearchIndices(chapterCount: Int, windowIndex: Int): List<Int> {
    if (chapterCount <= 0) return emptyList()
    val center = windowIndex.coerceIn(0, chapterCount - 1)
    return buildList(chapterCount) {
        add(center)
        var distance = 1
        while (size < chapterCount) {
            val before = center - distance
            if (before >= 0) add(before)
            val after = center + distance
            if (after < chapterCount) add(after)
            distance += 1
        }
    }
}

internal fun readAloudHighlightPositionMs(playerPositionMs: Long, syncOffsetMs: Long): Long = when {
    syncOffsetMs > 0L && playerPositionMs > Long.MAX_VALUE - syncOffsetMs -> Long.MAX_VALUE
    syncOffsetMs < 0L && playerPositionMs < Long.MIN_VALUE - syncOffsetMs -> 0L
    else -> (playerPositionMs + syncOffsetMs).coerceAtLeast(0L)
}

internal fun readAloudPageFlipDelayMs(
    clipDurationMs: Long,
    elapsedClipMs: Long,
    visibleRatio: Double,
    playbackSpeed: Float,
    leadMs: Long = 1_000L,
): Long {
    val mediaMillisUntilSplit = (
        clipDurationMs.coerceAtLeast(0L) * visibleRatio.coerceIn(0.0, 1.0) -
            elapsedClipMs.coerceAtLeast(0L)
    ).coerceAtLeast(0.0)
    val playbackMillis = mediaMillisUntilSplit /
        playbackSpeed.coerceIn(0.5f, 3.0f)
    return (playbackMillis - leadMs.coerceAtLeast(0L)).roundToLong().coerceAtLeast(0L)
}

internal fun shouldCorrectReadAloudPosition(
    playerPositionMs: Long,
    highlightPositionMs: Long,
    clipBeginMs: Long,
): Boolean = playerPositionMs < clipBeginMs && highlightPositionMs < clipBeginMs

internal fun resolveReadAloudForwardIndex(
    clips: List<SmilClip>,
    currentIndex: Int,
    candidateIndex: Int,
    skipSkippableClips: Boolean,
): Int? {
    val candidate = clips.getOrNull(candidateIndex) ?: return null
    if (!skipSkippableClips || candidateIndex <= currentIndex || !candidate.skippable) {
        return candidateIndex
    }
    return (candidateIndex..clips.lastIndex).firstOrNull { !clips[it].skippable }
}

class MediaOverlayEngine(
    context: Context,
    private val publication: Publication,
    parentScope: CoroutineScope,
    private val sourceFile: File? = null,
    private val playback: ReadAloudPlaybackCoordinator? = null,
    private val playbackSession: ReadAloudPlaybackSession? = null,
) {
    private data class ExternalAudioWindow(
        val index: Int,
        val startMs: Long,
        val durationMs: Long,
        val keys: Set<String>,
        val readAloudStems: Set<String>,
    )

    companion object {
        private const val TAG = "MediaOverlayEngine"
        private const val CACHE_DIR = "read_along_audio"
        private const val CLIP_MONITOR_INTERVAL_MS = 40L
        private const val MAX_DECODER_RETRIES_PER_AUDIO = 1
        private const val AUDIO_READ_CHUNK = 8L * 1024 * 1024
    }

    private val appContext = context.applicationContext
    private val engineJob = SupervisorJob(parentScope.coroutineContext[Job])
    private val scope = CoroutineScope(parentScope.coroutineContext + engineJob)
    private val audioCacheDirectory = File(
        File(appContext.cacheDir, CACHE_DIR),
        playbackSession?.id ?: "mapping-${System.identityHashCode(this)}",
    )

    private class ChapterMO(

        val spineHref: String,

        val smilLink: Link?,

        val smilZipPath: String?,

        val readingOrderIndex: Int,

        val bookStartMs: Long?,
        val durationMs: Long?,
    ) {
        val parseLock = Mutex()
        @Volatile var clips: List<SmilClip>? = null
        @Volatile var fragmentIndex: Map<String, Int>? = null
    }

    private var chaptersInReadingOrder: List<ChapterMO> = emptyList()

    private var chapterByHref: Map<String, ChapterMO> = emptyMap()

    private val zipFallbackPathByHref = linkedMapOf<String, String>()

    private val extractedAudioFiles = ConcurrentHashMap<String, File>()
    private var externalAudioWindows: List<ExternalAudioWindow> = emptyList()
    private var externalWindowIndexByExactKey: Map<String, Int> = emptyMap()
    private var externalWindowIndexByReadAloudStem: Map<String, Int> = emptyMap()

    @Volatile private var currentChapter: ChapterMO? = null
    @Volatile private var currentClipIndexInternal: Int? = null

    private var preparedAudioHref: String? = null
    private var pendingPlaybackCommand: ReadAloudPlaybackCommand? = null
    private var activePlaybackCommand: ReadAloudPlaybackCommand? = null
    private var playbackCommandJob: Job? = null
    private var clipMonitorJob: Job? = null
    private var playbackObserverJob: Job? = null
    private val playbackTransitionMutex = Mutex()
    private var decoderRetriesForCurrentAudio: Int = 0
    private var decoderRetryInFlight: Boolean = false
    private var playbackSpeed: Float = 1f
    private var lastObservedPlaying: Boolean? = null
    private var lastObservedPlayWhenReady: Boolean? = null
    private var observedPlaybackSession: Boolean = false
    private var sessionLostNotified: Boolean = false
    private var lastHandledEndedMediaId: String? = null
    private var lastHandledErrorRevision: Long = 0L
    @Volatile private var released: Boolean = false

    private var discoveryJob: Deferred<Unit>? = null

    var onClipChanged: ((SmilClip, Int) -> Unit)? = null
    var onPlaybackChanged: ((isPlaying: Boolean, playWhenReady: Boolean) -> Unit)? = null
    var onPlaybackCompleted: (() -> Unit)? = null
    var onPlaybackSessionLost: (() -> Unit)? = null
    var onPlaybackFailed: ((String) -> Unit)? = null

    var onPlaybackInfo: ((String) -> Unit)? = null

    @Volatile var syncOffsetMs: Long = 0L

    @Volatile var skipSkippableClips: Boolean = true

    val currentClipIndex: Int?
        get() = currentClipIndexInternal

    val clipCount: Int
        get() = currentChapter?.clips?.size ?: 0

    fun setAudioTimeline(tracks: List<AudioTrack>) {
        val orderedTracks = tracks.sortedBy { it.index }
        val offsets = cumulativeTrackOffsets(orderedTracks.map { it.durationMs })
        val isStorytellerM4bTimeline = orderedTracks.isNotEmpty() &&
            orderedTracks.withIndex().all { (position, track) ->
                val key = audioResourceKey(track.fileName)
                val stem = key.substringBeforeLast('.', key)
                stem == "${position.toString().padStart(5, '0')}-00001"
            }
        externalAudioWindows = orderedTracks.mapIndexed { index, track ->
            val window = ExternalAudioWindow(
                index = index,
                startMs = offsets[index],
                durationMs = track.durationMs.coerceAtLeast(0L),
                keys = listOfNotNull(track.fileName, track.title, track.contentUrl)
                    .map(::audioResourceKey)
                    .filter { it.isNotBlank() }
                    .toSet(),
                readAloudStems = if (isStorytellerM4bTimeline) {
                    listOfNotNull(track.fileName, track.title, track.contentUrl)
                        .mapNotNull(::storytellerReadAloudAudioStem)
                        .toSet()
                } else {
                    emptySet()
                },
            )
            window
        }
        externalWindowIndexByExactKey = buildMap {
            externalAudioWindows.forEach { window ->
                window.keys.forEach { key -> putIfAbsent(key, window.index) }
            }
        }
        externalWindowIndexByReadAloudStem = buildMap {
            externalAudioWindows.forEach { window ->
                window.readAloudStems.forEach { stem -> putIfAbsent(stem, window.index) }
            }
        }
    }

    init {
        val coordinator = playback
        val session = playbackSession
        if (coordinator != null && session != null) {
            coordinator.registerSessionLossHandler(session.id, ::handlePlaybackSessionLost)
            playbackObserverJob = scope.launch {
                coordinator.state.collect { state ->
                    if (state.sessionId != session.id) {
                        if (observedPlaybackSession) {
                            handlePlaybackSessionLost()
                        }
                        return@collect
                    }
                    observedPlaybackSession = true
                    val playbackChanged = lastObservedPlaying != state.isPlaying ||
                        lastObservedPlayWhenReady != state.playWhenReady
                    lastObservedPlaying = state.isPlaying
                    lastObservedPlayWhenReady = state.playWhenReady
                    if (playbackChanged && state.hasMediaItem) {
                        onPlaybackChanged?.invoke(state.isPlaying, state.playWhenReady)
                    }
                    if (state.isPlaying && currentChapter != null && currentClipIndexInternal != null &&
                        clipMonitorJob?.isActive != true
                    ) {
                        startClipMonitor()
                    }
                    if (state.playbackState == Player.STATE_ENDED && state.mediaId != lastHandledEndedMediaId) {
                        lastHandledEndedMediaId = state.mediaId
                        advanceFromPlayerEnd(state.mediaId)
                    }
                    if (state.errorRevision > lastHandledErrorRevision) {
                        lastHandledErrorRevision = state.errorRevision
                        handlePlaybackError(state.errorCode, state.errorCodeName.orEmpty())
                    }
                }
            }
        }
    }

    fun detectsSmil(): Boolean {
        val manifestHasSmil = publication.resources.any { link ->
            val href = link.url().toString().lowercase()
            val mediaType = (link.mediaType?.toString() ?: "").lowercase()
            href.endsWith(".smil") || mediaType.contains("smil")
        }
        if (manifestHasSmil) return true

        val src = sourceFile ?: return false
        if (!src.exists() || src.length() < 1024) return false
        return runCatching {
            java.util.zip.ZipFile(src).use { zip ->
                zip.entries().asSequence().any { entry ->
                    !entry.isDirectory && entry.name.lowercase().endsWith(".smil")
                }
            }
        }.getOrDefault(false)
    }

    private fun startDiscoveryIfNeeded() {
        if (discoveryJob == null) {
            discoveryJob = scope.async(Dispatchers.IO) { discoverInternal() }
        }
    }

    private suspend fun ensureDiscovered() {
        startDiscoveryIfNeeded()
        discoveryJob?.await()
    }

    private suspend fun discoverInternal() {
        val tStart = android.os.SystemClock.elapsedRealtime()

        val zipPathsByLowerName: Map<String, String> = sourceFile
            ?.takeIf { it.exists() && it.length() >= 1024 }
            ?.let { file ->
                runCatching {
                    java.util.zip.ZipFile(file).use { zip ->
                        val out = linkedMapOf<String, String>()
                        zip.entries().asSequence().forEach { e ->
                            if (!e.isDirectory) {
                                out[e.name.substringAfterLast('/').lowercase()] = e.name
                            }
                        }
                        out
                    }
                }.getOrElse { emptyMap() }
            }
            ?: emptyMap()

        val smilLinksByNormalizedHref = publication.resources
            .filter { link ->
                val href = link.url().toString().lowercase()
                val mediaType = (link.mediaType?.toString() ?: "").lowercase()
                href.endsWith(".smil") || mediaType.contains("smil")
            }
            .associateBy { normalizeHref(it.url().toString()) }

        val chapters = mutableListOf<ChapterMO>()
        var bookAudioCursorMs: Long? = 0L
        publication.readingOrder.forEachIndexed { roIndex, spineLink ->
            val spineHref = normalizeHref(spineLink.url().toString())

            val smilAlternate = spineLink.alternates.firstOrNull { alternate ->
                val href = alternate.url().toString().lowercase()
                val mediaType = alternate.mediaType?.toString()?.lowercase().orEmpty()
                href.endsWith(".smil") || mediaType.contains("smil")
            }

            val raw = spineLink.toJSON().toString().lowercase()
            val mentionsMediaOverlay = smilAlternate != null ||
                raw.contains("media-overlay") || raw.contains("mediaoverlay")

            val spineStem = spineHref.substringAfterLast('/').substringBeforeLast('.').lowercase()
            val zipSmilName = "$spineStem.smil"
            val zipSmilPath = zipPathsByLowerName[zipSmilName]

            val alternateSmilName = smilAlternate?.url()?.toString()?.substringAfterLast('/')?.lowercase()
            val manifestSmil = smilAlternate
                ?.url()
                ?.toString()
                ?.let(::normalizeHref)
                ?.let(smilLinksByNormalizedHref::get)
                ?: smilLinksByNormalizedHref.values.firstOrNull { link ->
                    alternateSmilName != null &&
                        link.url().toString().substringAfterLast('/').lowercase() == alternateSmilName
                }
                ?: smilLinksByNormalizedHref.values.firstOrNull { link ->
                val name = link.url().toString().substringAfterLast('/').lowercase()
                name == zipSmilName
            }

            val alternateZipPath = alternateSmilName?.let(zipPathsByLowerName::get)

            if (mentionsMediaOverlay || zipSmilPath != null || alternateZipPath != null || manifestSmil != null) {
                val durationMs = (smilAlternate?.duration ?: manifestSmil?.duration)
                    ?.takeIf { it > 0.0 }
                    ?.times(1000.0)
                    ?.roundToLong()
                chapters += ChapterMO(
                    spineHref = spineHref,
                    smilLink = manifestSmil,
                    smilZipPath = if (manifestSmil == null) alternateZipPath ?: zipSmilPath else null,
                    readingOrderIndex = roIndex,
                    bookStartMs = bookAudioCursorMs,
                    durationMs = durationMs,
                )
                bookAudioCursorMs = if (bookAudioCursorMs != null && durationMs != null) {
                    bookAudioCursorMs + durationMs
                } else {
                    null
                }
            }
        }

        chaptersInReadingOrder = chapters
        chapterByHref = chapters.associateBy { it.spineHref }
        Log.i(TAG, "Discovery: ${chapters.size} chapters with SMIL (out of ${publication.readingOrder.size} spine items) in ${android.os.SystemClock.elapsedRealtime() - tStart}ms")
    }

    private suspend fun parseChapter(chapter: ChapterMO): List<SmilClip>? {
        chapter.clips?.let { return it }
        chapter.parseLock.withLock {
            chapter.clips?.let { return it }
            val tStart = android.os.SystemClock.elapsedRealtime()
            val (smilXml, smilHrefForResolve) = readSmilFor(chapter)
                ?: run {
                    Log.w(TAG, "No SMIL bytes for chapter ${chapter.spineHref}")
                    chapter.clips = emptyList()
                    chapter.fragmentIndex = emptyMap()
                    return emptyList()
                }
            val parsed = runCatching {
                SmilParser.parse(smilXml, smilHrefForResolve)
            }.getOrElse { err ->
                Log.w(TAG, "Failed to parse SMIL for chapter ${chapter.spineHref}", err)
                null
            }
            val clipsRaw = parsed?.clips ?: emptyList()

            if (sourceFile != null) {
                val zipPaths: List<String> = runCatching {
                    java.util.zip.ZipFile(sourceFile).use { zip ->
                        buildList { zip.entries().asSequence().forEach { if (!it.isDirectory) add(it.name) } }
                    }
                }.getOrElse { emptyList() }
                if (zipPaths.isNotEmpty()) {
                    for (clip in clipsRaw) {
                        recordZipFallbackHref(clip.textHref, zipPaths)
                        recordZipFallbackHref(clip.audioHref, zipPaths)
                    }
                }
            }

            val lastIndex = (clipsRaw.size - 1).coerceAtLeast(1)
            val clips = clipsRaw.mapIndexed { index, clip ->
                clip.copy(
                    resourceProgression = if (clipsRaw.size <= 1) 0.0 else index.toDouble() / lastIndex.toDouble(),
                )
            }
            val fragIdx = buildMap<String, Int> {
                clips.forEachIndexed { i, c ->
                    c.textFragmentId?.let { putIfAbsent(it, i) }
                }
            }
            chapter.clips = clips
            chapter.fragmentIndex = fragIdx
            Log.i(TAG, "Parsed SMIL for ${chapter.spineHref} → ${clips.size} clips in ${android.os.SystemClock.elapsedRealtime() - tStart}ms")
            return clips
        }
    }

    private suspend fun readSmilFor(chapter: ChapterMO): Pair<String, String>? {

        chapter.smilLink?.let { link ->
            val xml = readResourceAsString(link)
            if (xml != null) return xml to link.url().toString()
        }

        val zipPath = chapter.smilZipPath ?: return null
        val src = sourceFile ?: return null
        val bytes = withContext(Dispatchers.IO) {
            runCatching {
                java.util.zip.ZipFile(src).use { zip ->
                    val entry = zip.getEntry(zipPath) ?: return@use null
                    zip.getInputStream(entry).use { it.readBytes() }
                }
            }.getOrNull()
        } ?: return null
        return bytes.toString(Charsets.UTF_8) to zipPath
    }

    private suspend fun readResourceAsString(link: Link): String? {
        val resource = publication.get(link) ?: return null
        return try {
            resource.read().getOrElse {
                Log.w(TAG, "Failed to read SMIL ${link.url()}: ${it.message}")
                return null
            }.decodeToString()
        } finally {
            resource.close()
        }
    }

    private fun launchPlaybackCommand(block: suspend () -> Unit): Job = scope.launch {
        try {
            block()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Log.e(TAG, "Read-aloud playback command failed", error)
            onPlaybackFailed?.invoke("Couldn't start read-aloud playback. Try again.")
        }
    }

    fun beginPlaybackPreparation() {
        val coordinator = playback ?: return
        val session = playbackSession ?: return
        pendingPlaybackCommand = beginPlaybackCommand(coordinator, session)
    }

    fun play(textHref: String, fragmentId: String? = null, resourceProgression: Double? = null) {
        val coordinator = playback
        val session = playbackSession
        if (coordinator == null || session == null) {
            onPlaybackFailed?.invoke("Read-aloud playback isn't available.")
            return
        }
        clipMonitorJob?.cancel()
        playbackCommandJob?.cancel()
        val command = pendingPlaybackCommand
            ?.also { pendingPlaybackCommand = null }
            ?: beginPlaybackCommand(coordinator, session)
        playbackCommandJob = launchPlaybackCommand {
            ensureDiscovered()
            if (chaptersInReadingOrder.isEmpty()) {
                onPlaybackFailed?.invoke("This book doesn't have read-aloud audio.")
                return@launchPlaybackCommand
            }

            val normalizedHref = normalizeHref(textHref)

            val activeCh = currentChapter
            val activeIdx = currentClipIndexInternal
            if (activeCh != null && activeIdx != null && activeCh.spineHref == normalizedHref) {
                val activeClip = activeCh.clips?.getOrNull(activeIdx)
                if (activeClip != null && (fragmentId == null || activeClip.textFragmentId == fragmentId)) {
                    if (preparedAudioHref == activeClip.audioHref && coordinator.hasMediaItem(session.id)) {
                        activePlaybackCommand = command
                        coordinator.play(session.id)
                        startClipMonitor()
                    } else {
                        startPlayback(activeCh, activeIdx, playWhenReady = true, notifyClipChanged = false, command)
                    }
                    return@launchPlaybackCommand
                }
            }

            val (chapter, startIndex, fellBackToZero) = locateStart(normalizedHref, fragmentId, resourceProgression)
                ?: run {
                    onPlaybackFailed?.invoke("Couldn't match read aloud to this page.")
                    return@launchPlaybackCommand
                }
            if (fellBackToZero) {
                onPlaybackInfo?.invoke("Couldn't match read aloud to this page. Starting from the chapter beginning.")
            }

            startPlayback(chapter, startIndex, playWhenReady = true, notifyClipChanged = true, command)
        }
    }

    fun resume() {
        val coordinator = playback ?: return
        val session = playbackSession ?: return
        val ch = currentChapter ?: return
        val idx = currentClipIndexInternal ?: return
        val clip = ch.clips?.getOrNull(idx) ?: return
        playbackCommandJob?.cancel()
        val command = beginPlaybackCommand(coordinator, session)
        playbackCommandJob = launchPlaybackCommand {
            if (preparedAudioHref == clip.audioHref && coordinator.hasMediaItem(session.id)) {
                coordinator.play(session.id)
                activePlaybackCommand = command
                startClipMonitor()
            } else {
                startPlayback(ch, idx, playWhenReady = true, notifyClipChanged = false, command)
            }
        }
    }

    fun pause() {
        clipMonitorJob?.cancel()
        val sessionId = playbackSession?.id ?: return
        playback?.pause(sessionId)
    }

    fun stop(clearPlaybackQueue: Boolean = true) {
        stop(clearPlaybackQueue, afterStopped = null)
    }

    private fun stop(clearPlaybackQueue: Boolean, afterStopped: (() -> Unit)?) {
        playbackCommandJob?.cancel()
        playbackCommandJob = null
        clipMonitorJob?.cancel()
        clipMonitorJob = null
        currentChapter = null
        currentClipIndexInternal = null
        preparedAudioHref = null
        pendingPlaybackCommand = null
        activePlaybackCommand = null
        if (clearPlaybackQueue) sessionLostNotified = true
        val sessionId = playbackSession?.id
        if (sessionId != null) {
            if (clearPlaybackQueue) {
                playback?.stop(sessionId, afterStopped) ?: afterStopped?.invoke()
            } else {
                playback?.pause(sessionId)
                afterStopped?.invoke()
            }
        } else {
            afterStopped?.invoke()
        }
        onPlaybackChanged?.invoke(false, false)
    }

    fun cancelPendingPlayback() {
        playbackCommandJob?.cancel()
        playbackCommandJob = null
        pendingPlaybackCommand = null
        activePlaybackCommand = null
        sessionLostNotified = true
        playbackSession?.id?.let { playback?.stop(it) }
    }

    fun setPlaybackSpeed(speed: Float) {
        playbackSpeed = speed.coerceIn(0.5f, 3.0f)
        playbackSession?.id?.let { playback?.setPlaybackSpeed(it, playbackSpeed) }
    }

    fun skipForward() {
        val coordinator = playback ?: return
        val session = playbackSession ?: return
        if (currentChapter == null || currentClipIndexInternal == null) return
        clipMonitorJob?.cancel()
        playbackCommandJob?.cancel()
        val command = beginPlaybackCommand(coordinator, session)
        playbackCommandJob = launchPlaybackCommand {
            ensureDiscovered()
            val ch = currentChapter
            val idx = currentClipIndexInternal
            val clips = ch?.clips
            val isPlaying = coordinator.isPlaying(session.id)
            if (ch == null || idx == null || clips == null) return@launchPlaybackCommand
            val nextIdx = idx + 1
            if (nextIdx <= clips.lastIndex) {
                startPlayback(ch, nextIdx, playWhenReady = isPlaying, notifyClipChanged = true, command)
            } else {

                val nextChIdx = ch.readingOrderIndex + 1
                val nextCh = chaptersInReadingOrder.firstOrNull { it.readingOrderIndex >= nextChIdx }
                if (nextCh != null) {
                    val parsedClips = parseChapter(nextCh) ?: return@launchPlaybackCommand
                    if (parsedClips.isNotEmpty()) {
                        startPlayback(nextCh, 0, playWhenReady = isPlaying, notifyClipChanged = true, command)
                    } else {
                        onPlaybackCompleted?.invoke()
                        stop(clearPlaybackQueue = true)
                    }
                } else {
                    onPlaybackCompleted?.invoke()
                    stop(clearPlaybackQueue = true)
                }
            }
        }
    }

    fun skipBackward() {
        val coordinator = playback ?: return
        val session = playbackSession ?: return
        if (currentChapter == null || currentClipIndexInternal == null) return
        clipMonitorJob?.cancel()
        playbackCommandJob?.cancel()
        val command = beginPlaybackCommand(coordinator, session)
        playbackCommandJob = launchPlaybackCommand {
            ensureDiscovered()
            val ch = currentChapter ?: return@launchPlaybackCommand
            val idx = currentClipIndexInternal ?: 0
            val clips = ch.clips ?: return@launchPlaybackCommand
            val clip = clips.getOrNull(idx) ?: return@launchPlaybackCommand
            val currentPosition = coordinator.currentPositionMs(session.id) ?: clip.clipBeginMs
            val isPlaying = coordinator.isPlaying(session.id)
            val restartCurrent = currentPosition - clip.clipBeginMs > 1_000L
            val target = if (restartCurrent) idx else idx - 1
            if (target >= 0) {
                startPlayback(ch, target, playWhenReady = isPlaying, notifyClipChanged = true, command)
            } else {

                val prevCh = chaptersInReadingOrder.lastOrNull { it.readingOrderIndex < ch.readingOrderIndex }
                if (prevCh != null) {
                    val parsedClips = parseChapter(prevCh) ?: return@launchPlaybackCommand
                    if (parsedClips.isNotEmpty()) {
                        startPlayback(prevCh, parsedClips.lastIndex, playWhenReady = isPlaying, notifyClipChanged = true, command)
                    }
                }
            }
        }
    }

    suspend fun syncToLocation(
        textHref: String,
        fragmentId: String? = null,
        resourceProgression: Double? = null,
    ): SmilClip? {
        ensureDiscovered()
        val located = locateStart(normalizeHref(textHref), fragmentId, resourceProgression) ?: return null
        val (chapter, index, _) = located
        currentChapter = chapter
        currentClipIndexInternal = index
        return chapter.clips?.getOrNull(index)
    }

    suspend fun currentClip(): SmilClip? {
        val ch = currentChapter ?: return null
        val idx = currentClipIndexInternal ?: return null
        return ch.clips?.getOrNull(idx)
    }

    fun currentClipSnapshot(): SmilClip? {
        val ch = currentChapter ?: return null
        val idx = currentClipIndexInternal ?: return null
        return ch.clips?.getOrNull(idx)
    }

    fun currentPageFlipDelayMs(visibleRatio: Double, leadMs: Long = 1_000L): Long? {
        val chapter = currentChapter ?: return null
        val index = currentClipIndexInternal ?: return null
        val clip = chapter.clips?.getOrNull(index) ?: return null
        val sessionId = playbackSession?.id ?: return null
        val playerPosition = playback?.currentPositionMs(sessionId) ?: clip.clipBeginMs
        val clipEnd = effectiveClipEndMs(chapter, index) ?: return null
        return readAloudPageFlipDelayMs(
            clipDurationMs = (clipEnd - clip.clipBeginMs).coerceAtLeast(0L),
            elapsedClipMs = (playerPosition - clip.clipBeginMs).coerceAtLeast(0L),
            visibleRatio = visibleRatio,
            playbackSpeed = playbackSpeed,
            leadMs = leadMs,
        )
    }

    suspend fun chapterClips(preferredTextHref: String?): List<SmilClip> {
        ensureDiscovered()
        val chapter = currentChapter
            ?: preferredTextHref?.let { chapterByHref[normalizeHref(it)] }
            ?: return emptyList()
        return parseChapter(chapter) ?: emptyList()
    }

    suspend fun firstVisibleClip(visibleFragmentIds: List<String>, preferredTextHref: String?): SmilClip? {
        ensureDiscovered()
        val preferredNormalized = preferredTextHref?.let(::normalizeHref)
        val preferredChapter = preferredNormalized?.let(chapterByHref::get)

        if (preferredChapter != null) {
            val clips = parseChapter(preferredChapter) ?: return null
            val idx = preferredChapter.fragmentIndex ?: return null
            for (frag in visibleFragmentIds) {
                idx[frag]?.let { i -> return clips.getOrNull(i) }
            }
            return null
        }
        return null
    }

    suspend fun bestClipForFragment(fragmentId: String, preferredTextHref: String?): SmilClip? {
        ensureDiscovered()
        val preferredNormalized = preferredTextHref?.let(::normalizeHref)
        val preferredChapter = preferredNormalized?.let(chapterByHref::get)
        if (preferredChapter != null) {
            val clips = parseChapter(preferredChapter) ?: return null
            val idx = preferredChapter.fragmentIndex?.get(fragmentId) ?: return null
            return clips.getOrNull(idx)
        }
        return null
    }

    suspend fun firstClipForHref(textHref: String, resourceProgression: Double?): SmilClip? {
        ensureDiscovered()
        val normalized = normalizeHref(textHref)
        val chapter = chapterByHref[normalized]
            ?: chaptersInReadingOrder.firstOrNull { it.spineHref.endsWith(normalized.substringAfterLast('/')) }
            ?: return null
        val clips = parseChapter(chapter) ?: return null
        if (clips.isEmpty()) return null
        val target = resourceProgression?.let { p ->
            val coerced = p.coerceIn(0.0, 1.0)
            clips.minByOrNull { abs((it.resourceProgression ?: 0.0) - coerced) }
        } ?: clips.first()
        return target
    }

    suspend fun clipForAbsoluteAudioPosition(positionMs: Long): SmilClip? {
        ensureDiscovered()
        if (chaptersInReadingOrder.isEmpty()) return null

        val target = positionMs.coerceAtLeast(0L)
        val externalWindow = if (externalAudioWindows.any { it.durationMs > 0L }) {
            externalAudioWindows.firstOrNull { window ->
                window.durationMs > 0L && target >= window.startMs && target < window.startMs + window.durationMs
            } ?: externalAudioWindows.lastOrNull { target >= it.startMs }
        } else {
            externalAudioWindows.singleOrNull()
        }
        if (externalWindow != null && externalWindow.keys.isNotEmpty()) {
            clipForExternalAudioPosition(
                window = externalWindow,
                localPositionMs = (target - externalWindow.startMs).coerceAtLeast(0L),
            )?.let { return it }
        }

        val chapter = chaptersInReadingOrder.firstOrNull { candidate ->
            val start = candidate.bookStartMs ?: return@firstOrNull false
            val duration = candidate.durationMs ?: return@firstOrNull false
            target < start + duration
        }
        if (chapter != null) {
            val chapterStart = chapter.bookStartMs ?: return null
            val clips = parseChapter(chapter).orEmpty()
            if (clips.isEmpty()) return null
            val localPosition = (target - chapterStart).coerceAtLeast(0L)
            var cursor = 0L
            clips.forEachIndexed { index, clip ->
                val duration = overlayClipDurationMs(clips, index)
                if (localPosition < cursor + duration || index == clips.lastIndex) return clip
                cursor += duration
            }
            return clips.last()
        }
        return null
    }

    private suspend fun clipForExternalAudioPosition(
        window: ExternalAudioWindow,
        localPositionMs: Long,
    ): SmilClip? {
        val prioritized = buildList {
            chaptersInReadingOrder.filterTo(this) { chapter ->
                chapter.clips?.any { externalWindowMatches(window, it.audioHref) } == true
            }
            chaptersInReadingOrder.filterTo(this) { chapter ->
                val smilStem = (chapter.smilLink?.url()?.toString() ?: chapter.smilZipPath)
                    ?.substringAfterLast('/')
                    ?.substringBeforeLast('.')
                    ?.lowercase()
                smilStem != null && (window.keys + window.readAloudStems).any {
                    it.substringBeforeLast('.', it) == smilStem
                }
            }
            chaptersInReadingOrder.getOrNull(window.index)?.let(::add)
        }.distinct()

        val visited = mutableSetOf<ChapterMO>()
        suspend fun matchingClips(chapter: ChapterMO): List<SmilClip> {
            visited += chapter
            return parseChapter(chapter).orEmpty()
                .filter { externalWindowMatches(window, it.audioHref) }
                .sortedBy(SmilClip::clipBeginMs)
        }

        var closestBefore: SmilClip? = null
        var closestAfter: SmilClip? = null
        fun updateClosest(clips: List<SmilClip>) {
            clips.lastOrNull { it.clipBeginMs <= localPositionMs }?.let { candidate ->
                if (closestBefore == null || candidate.clipBeginMs > closestBefore!!.clipBeginMs) {
                    closestBefore = candidate
                }
            }
            clips.firstOrNull { it.clipBeginMs > localPositionMs }?.let { candidate ->
                if (closestAfter == null || candidate.clipBeginMs < closestAfter!!.clipBeginMs) {
                    closestAfter = candidate
                }
            }
        }

        for (chapter in prioritized) {
            val clips = matchingClips(chapter)
            if (clips.containsAudioPosition(localPositionMs)) {
                return clips.lastOrNull { it.clipBeginMs <= localPositionMs } ?: clips.firstOrNull()
            }
            updateClosest(clips)
        }

        for (chapterIndex in externalAudioChapterSearchIndices(chaptersInReadingOrder.size, window.index)) {
            val chapter = chaptersInReadingOrder[chapterIndex]
            if (chapter in visited) continue
            val clips = matchingClips(chapter)
            if (clips.isEmpty()) continue
            if (clips.containsAudioPosition(localPositionMs)) {
                return clips.lastOrNull { it.clipBeginMs <= localPositionMs } ?: clips.first()
            }
            updateClosest(clips)
        }
        return closestBefore ?: closestAfter
    }

    private fun List<SmilClip>.containsAudioPosition(positionMs: Long): Boolean {
        if (isEmpty() || positionMs < first().clipBeginMs) return false
        val finalEnd = last().clipEndMs ?: last().clipBeginMs
        return positionMs <= finalEnd
    }

    suspend fun absoluteAudioPositionForLocation(
        textHref: String,
        fragmentId: String? = null,
        resourceProgression: Double? = null,
    ): Long? {
        ensureDiscovered()
        val located = locateStart(normalizeHref(textHref), fragmentId, resourceProgression) ?: return null
        return absoluteAudioPositionForClip(located.first, located.second)
    }

    fun currentAbsoluteAudioPositionMs(): Long? {
        val chapter = currentChapter ?: return null
        val index = currentClipIndexInternal ?: return null
        val clips = chapter.clips ?: return null
        val clip = clips.getOrNull(index) ?: return null
        val sessionId = playbackSession?.id ?: return null
        val playerPosition = playback?.currentPositionMs(sessionId) ?: return null
        return resolveReadAloudAbsoluteAudioPosition(
            externalWindowStartMs = externalWindowForAudioHref(clip.audioHref)?.startMs,
            playerPositionMs = playerPosition,
            overlayChapterStartMs = chapter.bookStartMs,
            overlayElapsedBeforeClipMs = overlayElapsedBeforeClip(clips, index),
            clipBeginMs = clip.clipBeginMs,
            clipDurationMs = overlayClipDurationMs(clips, index),
        )
    }

    fun currentAudioProgression(): Float? {
        val position = currentAbsoluteAudioPositionMs() ?: return null
        val total = externalAudioWindows.lastOrNull()
            ?.let { it.startMs + it.durationMs }
            ?.takeIf { it > 0L }
            ?: declaredTotalAudioDurationMs()
            ?: return null
        if (total <= 0L) return null
        return (position.toFloat() / total.toFloat()).coerceIn(0f, 1f)
    }

    suspend fun hasClipFragment(fragmentId: String): Boolean {
        ensureDiscovered()

        val ch = currentChapter ?: return false
        val parsed = ch.fragmentIndex ?: return false
        return parsed.containsKey(fragmentId)
    }

    fun release(stopPlayback: Boolean = true) {
        if (released) return
        released = true
        val cacheDirectory = audioCacheDirectory
        extractedAudioFiles.clear()
        val cleanup: () -> Unit = { runCatching { cacheDirectory.deleteRecursively() }; Unit }
        if (stopPlayback) {
            stop(clearPlaybackQueue = true, afterStopped = cleanup)
        } else {
            playbackCommandJob?.cancel()
            playbackCommandJob = null
            clipMonitorJob?.cancel()
            clipMonitorJob = null
            cleanup()
        }
        playbackObserverJob?.cancel()
        playbackObserverJob = null
        playbackSession?.id?.let { playback?.unregisterSessionLossHandler(it) }
        discoveryJob?.cancel()
        engineJob.cancel()
        chaptersInReadingOrder.forEach { it.parseLock  }
    }

    private suspend fun locateStart(
        normalizedHref: String,
        fragmentId: String?,
        resourceProgression: Double?,
    ): Triple<ChapterMO, Int, Boolean>? {

        val chapter = chapterByHref[normalizedHref]
            ?: chaptersInReadingOrder.firstOrNull { it.spineHref.endsWith(normalizedHref.substringAfterLast('/')) }
            ?: return null
        val clips = parseChapter(chapter) ?: return null
        if (clips.isEmpty()) return null

        if (fragmentId != null) {
            chapter.fragmentIndex?.get(fragmentId)?.let { idx ->
                return Triple(chapter, idx, false)
            }
        }

        if (resourceProgression != null) {
            val coerced = resourceProgression.coerceIn(0.0, 1.0)
            val nearest = clips.withIndex().minByOrNull { (_, c) ->
                abs((c.resourceProgression ?: 0.0) - coerced)
            }
            if (nearest != null) return Triple(chapter, nearest.index, false)
        }

        return Triple(chapter, 0, true)
    }

    private fun recordZipFallbackHref(href: String, zipPaths: List<String>) {
        if (zipFallbackPathByHref.containsKey(href)) return
        val candidate = java.net.URLDecoder.decode(href, "UTF-8").trimStart('/')
        val match = zipPaths.firstOrNull { it == candidate }
            ?: zipPaths.firstOrNull { it.endsWith("/$candidate") || it.equals(candidate, ignoreCase = true) }
            ?: zipPaths.firstOrNull {
                val name = it.substringAfterLast('/')
                name == candidate.substringAfterLast('/')
            }
        if (match != null) {
            zipFallbackPathByHref[href] = match
        }
    }

    private suspend fun startPlayback(
        chapter: ChapterMO,
        index: Int,
        playWhenReady: Boolean,
        notifyClipChanged: Boolean,
        command: ReadAloudPlaybackCommand? = null,
    ) = playbackTransitionMutex.withLock {
        val coordinator = playback ?: return@withLock
        if (playbackSession == null) return@withLock
        val resolvedCommand = command
            ?: activePlaybackCommand?.takeIf(coordinator::isCommandCurrent)
            ?: return@withLock
        startPlaybackLocked(chapter, index, playWhenReady, notifyClipChanged, resolvedCommand)
    }

    private fun beginPlaybackCommand(
        coordinator: ReadAloudPlaybackCoordinator,
        session: ReadAloudPlaybackSession,
    ): ReadAloudPlaybackCommand {
        sessionLostNotified = false
        return coordinator.beginCommand(session.id)
    }

    private fun handlePlaybackSessionLost() {
        if (sessionLostNotified || released) return
        sessionLostNotified = true
        observedPlaybackSession = false
        playbackCommandJob?.cancel()
        playbackCommandJob = null
        pendingPlaybackCommand = null
        preparedAudioHref = null
        activePlaybackCommand = null
        clipMonitorJob?.cancel()
        clipMonitorJob = null
        lastObservedPlaying = false
        lastObservedPlayWhenReady = false
        onPlaybackChanged?.invoke(false, false)
        onPlaybackSessionLost?.invoke()
    }

    private suspend fun startPlaybackLocked(
        chapter: ChapterMO,
        index: Int,
        playWhenReady: Boolean,
        notifyClipChanged: Boolean,
        command: ReadAloudPlaybackCommand,
    ) {
        val tStart = android.os.SystemClock.elapsedRealtime()
        val clips = chapter.clips ?: parseChapter(chapter) ?: return
        val clip = clips.getOrNull(index) ?: return
        val coordinator = playback ?: return
        val session = playbackSession ?: return

        val tExtract = android.os.SystemClock.elapsedRealtime()
        val audioFile = extractAudioFile(clip.audioHref) ?: return
        currentCoroutineContext().ensureActive()
        if (released) return
        Log.i(TAG, "startPlayback: extractAudio ms=${android.os.SystemClock.elapsedRealtime() - tExtract}")

        if (preparedAudioHref != clip.audioHref || !coordinator.hasMediaItem(session.id)) {
            val tPrep = android.os.SystemClock.elapsedRealtime()
            val applied = coordinator.prepareAndPlay(
                command = command,
                trackKey = clip.audioHref,
                audioFile = audioFile,
                title = session.title,
                author = session.author,
                startPositionMs = clip.clipBeginMs,
                playbackSpeed = playbackSpeed,
                playWhenReady = playWhenReady,
            )
            if (!applied) return
            preparedAudioHref = clip.audioHref
            activePlaybackCommand = command
            decoderRetriesForCurrentAudio = 0
            Log.i(TAG, "startPlayback: setMediaItem+prepare ms=${android.os.SystemClock.elapsedRealtime() - tPrep}")
        } else {
            if (!coordinator.seekAndSetPlaying(command, clip.clipBeginMs, playWhenReady)) return
            activePlaybackCommand = command
        }

        currentChapter = chapter
        currentClipIndexInternal = index
        lastHandledEndedMediaId = null
        if (notifyClipChanged) {
            onClipChanged?.invoke(clip, index)
        }

        if (playWhenReady) {
            startClipMonitor()
        }
        Log.i(TAG, "startPlayback: total ms=${android.os.SystemClock.elapsedRealtime() - tStart}")
    }

    private fun startClipMonitor() {
        clipMonitorJob?.cancel()
        clipMonitorJob = scope.launch {
            while (isActive) {
                val ch = currentChapter ?: return@launch
                val idx = currentClipIndexInternal ?: return@launch
                val clips = ch.clips ?: return@launch
                val clip = clips.getOrNull(idx) ?: return@launch
                val effectiveEnd = effectiveClipEndMs(ch, idx)
                val sessionId = playbackSession?.id ?: return@launch
                val coordinator = playback ?: return@launch
                val playbackState = coordinator.state.value
                if (playbackState.sessionId != sessionId) return@launch
                val playerPosition = playbackState.positionMs
                val highlightPosition = readAloudHighlightPositionMs(playerPosition, syncOffsetMs)

                val reconciledIndex = clipIndexAtPlayerPosition(clips, clip.audioHref, highlightPosition)
                if (reconciledIndex != null && reconciledIndex != idx) {
                    val targetIndex = resolveReadAloudForwardIndex(
                        clips = clips,
                        currentIndex = idx,
                        candidateIndex = reconciledIndex,
                        skipSkippableClips = skipSkippableClips,
                    )
                    if (targetIndex != null) {
                        if (targetIndex != reconciledIndex) {
                            startPlayback(ch, targetIndex, playWhenReady = true, notifyClipChanged = true)
                            return@launch
                        }
                        currentClipIndexInternal = targetIndex
                        onClipChanged?.invoke(clips[targetIndex], targetIndex)
                        delay(CLIP_MONITOR_INTERVAL_MS)
                        continue
                    }
                }

                if (effectiveEnd != null && highlightPosition >= effectiveEnd - 30L) {
                    val nextIdx = nextAutoAdvanceIndex(clips, idx + 1)
                    if (nextIdx == null) {

                        val nextCh = chaptersInReadingOrder.firstOrNull { it.readingOrderIndex > ch.readingOrderIndex }
                        if (nextCh == null) {
                            onPlaybackCompleted?.invoke()
                            stop(clearPlaybackQueue = true)
                            return@launch
                        }

                        val nextClips = parseChapter(nextCh) ?: emptyList()
                        val nextStart = nextAutoAdvanceIndex(nextClips, 0)
                        if (nextStart == null) {
                            onPlaybackCompleted?.invoke()
                            stop(clearPlaybackQueue = true)
                            return@launch
                        }
                        startPlayback(nextCh, nextStart, playWhenReady = true, notifyClipChanged = true)
                        return@launch
                    }
                    val nextClip = clips[nextIdx]
                    if (nextIdx == idx + 1 && nextClip.audioHref == clip.audioHref) {

                        currentClipIndexInternal = nextIdx
                        onClipChanged?.invoke(nextClip, nextIdx)
                    } else {

                        startPlayback(ch, nextIdx, playWhenReady = true, notifyClipChanged = true)
                        return@launch
                    }
                }

                if (!playbackState.isPlaying) {
                    delay(250L)
                    continue
                }

                if (shouldCorrectReadAloudPosition(playerPosition, highlightPosition, clip.clipBeginMs)) {
                    coordinator.seekTo(sessionId, clip.clipBeginMs)
                }

                delay(CLIP_MONITOR_INTERVAL_MS)
            }
        }
    }

    private suspend fun advanceFromPlayerEnd(endedMediaId: String?) {
        val coordinator = playback ?: return
        if (playbackSession == null) return
        playbackTransitionMutex.withLock {
        val playbackState = coordinator.state.value
        if (endedMediaId == null || playbackState.mediaId != endedMediaId || playbackState.playbackState != Player.STATE_ENDED) return
        val command = activePlaybackCommand?.takeIf(coordinator::isCommandCurrent) ?: return
        val ch = currentChapter ?: return
        val idx = currentClipIndexInternal ?: return
        val clips = ch.clips ?: return
        val nextIdx = nextAutoAdvanceIndex(clips, idx + 1)
        if (nextIdx != null) {
            startPlaybackLocked(ch, nextIdx, playWhenReady = true, notifyClipChanged = true, command)
            return
        }

        val nextCh = chaptersInReadingOrder.firstOrNull { it.readingOrderIndex > ch.readingOrderIndex }
        if (nextCh == null) {
            onPlaybackCompleted?.invoke()
            stop(clearPlaybackQueue = true)
            return
        }
        val nextClips = parseChapter(nextCh) ?: emptyList()
        val nextStart = nextAutoAdvanceIndex(nextClips, 0)
        if (nextStart == null) {
            onPlaybackCompleted?.invoke()
            stop(clearPlaybackQueue = true)
            return
        }
        startPlaybackLocked(nextCh, nextStart, playWhenReady = true, notifyClipChanged = true, command)
        }
    }

    fun reconcilePlaybackPosition() {
        scope.launch {
            val chapter = currentChapter ?: return@launch
            val clips = chapter.clips ?: return@launch
            val index = currentClipIndexInternal ?: return@launch
            val activeClip = clips.getOrNull(index) ?: return@launch
            val sessionId = playbackSession?.id ?: return@launch
            val state = playback?.state?.value ?: return@launch
            if (state.sessionId != sessionId || !state.hasMediaItem) return@launch
            if (state.playbackState == Player.STATE_ENDED) {
                advanceFromPlayerEnd(state.mediaId)
                return@launch
            }
            val highlightPosition = readAloudHighlightPositionMs(state.positionMs, syncOffsetMs)
            val targetIndex = clipIndexAtPlayerPosition(clips, activeClip.audioHref, highlightPosition)
                ?: return@launch
            if (targetIndex != index) {
                currentClipIndexInternal = targetIndex
                onClipChanged?.invoke(clips[targetIndex], targetIndex)
            }
            if (state.isPlaying) startClipMonitor()
        }
    }

    private fun nextAutoAdvanceIndex(clips: List<SmilClip>, from: Int): Int? {
        var idx = from
        while (idx <= clips.lastIndex) {
            if (!skipSkippableClips || !clips[idx].skippable) return idx
            idx++
        }
        return null
    }

    private fun effectiveClipEndMs(chapter: ChapterMO, index: Int): Long? {
        val clips = chapter.clips ?: return null
        val clip = clips.getOrNull(index) ?: return null
        clip.clipEndMs?.let { return it }
        val nextClip = clips.getOrNull(index + 1)
        if (nextClip != null && normalizeHref(nextClip.audioHref) == normalizeHref(clip.audioHref)) {
            return nextClip.clipBeginMs
        }
        return null
    }

    private fun clipIndexAtPlayerPosition(
        clips: List<SmilClip>,
        audioHref: String,
        positionMs: Long,
    ): Int? {
        val normalizedAudio = normalizeHref(audioHref)
        return clips.indices.lastOrNull { index ->
            val candidate = clips[index]
            normalizeHref(candidate.audioHref) == normalizedAudio && candidate.clipBeginMs <= positionMs
        }
    }

    private suspend fun extractAudioFile(audioHref: String): File? {
        if (released) return null
        extractedAudioFiles[audioHref]?.takeIf { it.exists() }?.let { return it }

        return withContext(Dispatchers.IO) {
            val audioUrl = parseUrl(audioHref)
            val cacheDir = audioCacheDirectory.apply { mkdirs() }
            val fallbackName = zipFallbackPathByHref[audioHref]?.substringAfterLast('/')
            val baseName = (audioUrl?.filename ?: fallbackName ?: "audio_${audioHref.hashCode()}")
                .replace(Regex("[^A-Za-z0-9._-]"), "_")
                .ifBlank { "audio_${audioHref.hashCode()}" }
            val file = File(cacheDir, "${audioHref.hashCode()}_$baseName")
            val tmp = File(cacheDir, "${file.name}.part")

            val ok = try {
                streamZipEntryToFile(audioHref, tmp) || streamResourceToFile(audioUrl, tmp)
            } catch (error: CancellationException) {
                tmp.delete()
                throw error
            }
            if (!ok) {
                tmp.delete()
                if (released) return@withContext null
                Log.w(TAG, "Read-aloud audio missing from EPUB: $audioHref")
                onPlaybackFailed?.invoke("Read-aloud audio is missing from this book.")
                return@withContext null
            }
            if (released) {
                tmp.delete()
                return@withContext null
            }
            if (file.exists()) file.delete()
            if (!tmp.renameTo(file)) {
                tmp.copyTo(file, overwrite = true)
                tmp.delete()
            }
            if (released) {
                file.delete()
                return@withContext null
            }
            extractedAudioFiles[audioHref] = file
            file
        }
    }

    private suspend fun streamZipEntryToFile(audioHref: String, dest: File): Boolean {
        val src = sourceFile ?: return false
        if (!zipFallbackPathByHref.containsKey(audioHref)) {
            runCatching {
                java.util.zip.ZipFile(src).use { zip ->
                    recordZipFallbackHref(audioHref, zip.entries().asSequence().map { it.name }.toList())
                }
            }
        }
        val entryName = zipFallbackPathByHref[audioHref] ?: return false
        return try {
            java.util.zip.ZipFile(src).use { zip ->
                val entry = zip.getEntry(entryName) ?: return@use false
                zip.getInputStream(entry).use { input ->
                    dest.outputStream().buffered().use { output ->
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                        }
                    }
                }
                true
            }
        } catch (error: CancellationException) {
            dest.delete()
            throw error
        } catch (_: Exception) {
            false
        }
    }

    private suspend fun streamResourceToFile(audioUrl: Url?, dest: File): Boolean {
        val resource = audioUrl?.let { publication.get(it) } ?: return false
        try {
            val length = resource.length().getOrElse {
                Log.w(TAG, "publication.get audio length failed: ${it.message}")
                return false
            }
            dest.outputStream().buffered().use { out ->
                var pos = 0L
                while (pos < length) {
                    currentCoroutineContext().ensureActive()
                    val end = minOf(pos + AUDIO_READ_CHUNK, length)
                    val chunk = resource.read(pos until end).getOrElse {
                        Log.w(TAG, "publication.get audio read failed: ${it.message}")
                        return false
                    }
                    out.write(chunk)
                    pos = end
                }
            }
            return true
        } finally {
            resource.close()
        }
    }

    private fun normalizeHref(href: String): String =
        parseUrl(href)?.normalize()?.removeFragment()?.toString() ?: href

    private fun parseUrl(rawHref: String): Url? =
        Url(rawHref) ?: Url.fromDecodedPath(rawHref)

    private fun absoluteAudioPositionForClip(chapter: ChapterMO, index: Int): Long? {
        val clips = chapter.clips ?: return null
        if (index !in clips.indices) return null
        val clip = clips[index]
        externalWindowForAudioHref(clip.audioHref)?.let { window ->
            return window.startMs + clip.clipBeginMs
        }
        return chapter.bookStartMs?.plus(overlayElapsedBeforeClip(clips, index))
    }

    private fun overlayElapsedBeforeClip(clips: List<SmilClip>, index: Int): Long =
        (0 until index.coerceAtMost(clips.size)).sumOf { overlayClipDurationMs(clips, it) }

    private fun overlayClipDurationMs(clips: List<SmilClip>, index: Int): Long {
        val clip = clips.getOrNull(index) ?: return 0L
        val end = clip.clipEndMs
            ?: clips.getOrNull(index + 1)
                ?.takeIf { normalizeHref(it.audioHref) == normalizeHref(clip.audioHref) }
                ?.clipBeginMs
            ?: clip.clipBeginMs
        return (end - clip.clipBeginMs).coerceAtLeast(0L)
    }

    private fun declaredTotalAudioDurationMs(): Long? {
        val last = chaptersInReadingOrder.lastOrNull() ?: return null
        val start = last.bookStartMs ?: return null
        val duration = last.durationMs ?: return null
        return start + duration
    }

    private fun externalWindowForAudioHref(audioHref: String): ExternalAudioWindow? {
        val index = resolveExternalAudioWindowIndex(
            audioHref = audioHref,
            exactKeyToIndex = externalWindowIndexByExactKey,
            readAloudStemToIndex = externalWindowIndexByReadAloudStem,
        ) ?: return null
        return externalAudioWindows.getOrNull(index)
    }

    private fun externalWindowMatches(window: ExternalAudioWindow, audioHref: String): Boolean =
        externalWindowForAudioHref(audioHref)?.index == window.index

    private fun handlePlaybackError(errorCode: Int?, errorCodeName: String) {
        val isTransient = errorCode == PlaybackException.ERROR_CODE_DECODER_INIT_FAILED ||
            errorCode == PlaybackException.ERROR_CODE_DECODER_QUERY_FAILED ||
            errorCode == PlaybackException.ERROR_CODE_DECODING_FAILED ||
            errorCode == PlaybackException.ERROR_CODE_AUDIO_TRACK_INIT_FAILED ||
            errorCode == PlaybackException.ERROR_CODE_AUDIO_TRACK_WRITE_FAILED
        val chapter = currentChapter
        val index = currentClipIndexInternal
        val canRetry = isTransient && chapter != null && index != null &&
            !decoderRetryInFlight && decoderRetriesForCurrentAudio < MAX_DECODER_RETRIES_PER_AUDIO
        if (canRetry) {
            decoderRetryInFlight = true
            decoderRetriesForCurrentAudio += 1
            preparedAudioHref = null
            scope.launch {
                try {
                    startPlayback(chapter, index, playWhenReady = true, notifyClipChanged = false)
                } catch (error: kotlinx.coroutines.CancellationException) {
                    throw error
                } catch (error: Exception) {
                    Log.w(TAG, "Decoder-recovery retry failed", error)
                    onPlaybackFailed?.invoke("Couldn't play read-aloud audio ($errorCodeName).")
                } finally {
                    decoderRetryInFlight = false
                }
            }
            return
        }
        val reason = if (isTransient && decoderRetriesForCurrentAudio >= MAX_DECODER_RETRIES_PER_AUDIO) {
            "System audio codec keeps failing. Try restarting the device. ($errorCodeName)"
        } else {
            "Couldn't play read-aloud audio ($errorCodeName)."
        }
        onPlaybackFailed?.invoke(reason)
    }
}
