package com.enve.app.readium

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import com.enve.app.readium.narrator.NarratorAudio
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.readium.r2.shared.publication.Locator

data class EbookTTSParagraph(val text: String, val locator: Locator? = null)

data class EbookTTSState(
    val active: Boolean = false,
    val playing: Boolean = false,
    val preparing: Boolean = false,
    val paragraph: Int = 0,
    val spoken: Locator? = null,
    val passage: String = "",
)

class EbookTTSService(
    private val scope: CoroutineScope,
    private val speak: (String, String) -> Boolean,
    private val stopSpeech: () -> Unit,
    private val onNavigate: (Locator) -> Unit,
    private val onFailure: (String) -> Unit,
    var maxInputLength: Int = 4_000,
    private val prepareSpeech: (String) -> Unit = {},
    private val pauseSpeech: () -> Boolean = { false },
    private val resumeSpeech: () -> Boolean = { false },
) {
    private val _state = MutableStateFlow(EbookTTSState())
    val state = _state.asStateFlow()
    private val history = mutableListOf<EbookTTSParagraph>()
    private var nextParagraph: (suspend () -> EbookTTSParagraph?)? = null
    private var contentJob: Job? = null
    private var generation = 0L
    private var sequence = 0L
    private var ready = false
    private var index = 0
    private var offset = 0
    private var spokenOffset = 0
    private var spokenLength = 0
    private var utteranceId: String? = null
    private var needsNext = false
    private var exhausted = false
    private var held = false

    fun setReady(ready: Boolean) {
        this.ready = ready
        if (ready && _state.value.playing && utteranceId == null && !needsNext) speakCurrent()
    }

    fun start(nextParagraph: suspend () -> EbookTTSParagraph?) {
        stop()
        this.nextParagraph = nextParagraph
        _state.value = EbookTTSState(active = true, playing = true, preparing = true)
        loadNext()
    }

    fun pause() {
        if (!_state.value.active) return
        if (!held) {
            if (utteranceId != null && pauseSpeech()) held = true else interrupt()
        }
        _state.value = _state.value.copy(playing = false, preparing = false)
    }

    fun resume() {
        if (!_state.value.active || _state.value.playing) return
        _state.value = _state.value.copy(playing = true, preparing = true)
        if (held) {
            held = false
            if (resumeSpeech()) return
            interrupt()
        }
        if (needsNext) {
            if (contentJob?.isActive != true) loadNext()
        } else {
            speakCurrent()
        }
    }

    fun restart() {
        if (held) {
            interrupt()
            return
        }
        if (!_state.value.playing) return
        interrupt()
        if (!needsNext) speakCurrent()
    }

    fun previous() {
        if (!_state.value.active || history.isEmpty()) return
        interrupt()
        if (needsNext) needsNext = false else index = (index - 1).coerceAtLeast(0)
        offset = 0
        _state.value = _state.value.copy(paragraph = index)
        if (_state.value.playing) speakCurrent()
    }

    fun next() {
        if (!_state.value.active || (needsNext && contentJob?.isActive == true)) return
        interrupt()
        offset = 0
        if (index < history.lastIndex) {
            index += 1
            _state.value = _state.value.copy(paragraph = index)
            if (_state.value.playing) speakCurrent()
        } else {
            loadNext()
        }
    }

    fun stop() {
        generation += 1
        contentJob?.cancel()
        contentJob = null
        interrupt()
        nextParagraph = null
        history.clear()
        index = 0
        offset = 0
        needsNext = false
        exhausted = false
        _state.value = EbookTTSState()
    }

    fun onStart(id: String?) {
        if (id == null || id != utteranceId) return
        val paragraph = history.getOrNull(index)
        _state.value = _state.value.copy(
            preparing = false,
            spoken = paragraph?.spokenWord(spokenOffset),
            passage = paragraph?.text?.substring(spokenOffset, spokenOffset + spokenLength)?.trim().orEmpty(),
        )
        paragraph?.locator?.let(onNavigate)
    }

    fun onRangeStart(id: String?, start: Int) {
        if (id == null || id != utteranceId || start !in 0 until spokenLength) return
        offset = spokenOffset + start
        history.getOrNull(index)?.spokenWord(offset)?.let { _state.value = _state.value.copy(spoken = it) }
    }

    fun onDone(id: String?) {
        if (id == null || id != utteranceId) return
        utteranceId = null
        offset = spokenOffset + spokenLength
        if (offset < history[index].text.length) speakCurrent() else next()
    }

    fun onError(id: String?) {
        if (id == null || id != utteranceId) return
        fail("Couldn't speak this passage. You can try another voice or resume.")
    }

    private fun interrupt() {
        held = false
        utteranceId = null
        stopSpeech()
    }

    private fun speakCurrent() {
        if (!_state.value.playing) return
        if (!ready) {
            _state.value = _state.value.copy(preparing = true)
            return
        }
        val paragraph = history.getOrNull(index) ?: return
        val end = chunkEnd(paragraph.text, offset)
        spokenOffset = offset
        spokenLength = end - offset
        val id = "enve-tts-${++sequence}"
        utteranceId = id
        _state.value = _state.value.copy(preparing = true)
        if (!speak(paragraph.text.substring(offset, end), id)) {
            onError(id)
            return
        }
        when {
            end < paragraph.text.length -> prepareSpeech(paragraph.text.substring(end, chunkEnd(paragraph.text, end)))
            index < history.lastIndex -> prepareOpening(history[index + 1])
            contentJob?.isActive != true && !exhausted -> fetch()
        }
    }

    private fun prepareOpening(paragraph: EbookTTSParagraph) {
        prepareSpeech(paragraph.text.substring(0, chunkEnd(paragraph.text, 0)))
    }

    private fun chunkEnd(text: String, start: Int): Int {
        val limit = (start + maxInputLength).coerceAtMost(text.length)
        if (limit == text.length) return limit
        var space = -1
        for (i in limit - 1 downTo start + maxInputLength / 2 + 1) {
            if (text[i] != ' ') continue
            if (text.endsSentenceBefore(i)) return i + 1
            if (space < 0) space = i
        }
        return when {
            space >= 0 -> space + 1
            text[limit - 1].isHighSurrogate() -> limit - 1
            else -> limit
        }
    }

    private fun loadNext() {
        needsNext = true
        _state.value = _state.value.copy(preparing = _state.value.playing)
        when {
            contentJob?.isActive == true -> Unit
            exhausted -> finish()
            else -> fetch()
        }
    }

    private fun fetch() {
        val load = nextParagraph ?: return
        val session = generation
        contentJob = scope.launch {
            try {
                var paragraph: EbookTTSParagraph?
                do {
                    paragraph = load()
                } while (paragraph != null && paragraph.text.isBlank())
                if (session != generation) return@launch
                contentJob = null
                if (paragraph == null) {
                    exhausted = true
                    if (needsNext) finish()
                    return@launch
                }
                history += paragraph
                if (needsNext) {
                    needsNext = false
                    index = history.lastIndex
                    offset = 0
                    _state.value = _state.value.copy(paragraph = index)
                    if (_state.value.playing) speakCurrent()
                } else if (
                    utteranceId != null && index == history.lastIndex - 1 &&
                    spokenOffset + spokenLength == history[index].text.length
                ) {
                    prepareOpening(paragraph)
                }
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                if (session != generation) return@launch
                contentJob = null
                if (needsNext) fail("Couldn't load this passage. Try starting read back again.")
            }
        }
    }

    private fun finish() {
        val wasEmpty = history.isEmpty()
        stop()
        if (wasEmpty) onFailure("No readable text was found here.")
    }

    private fun fail(message: String) {
        pause()
        onFailure(message)
    }
}

private const val SPOKEN_CONTEXT = 80

internal fun EbookTTSParagraph.spokenWord(from: Int): Locator? {
    val base = locator ?: return null
    var start = from.coerceIn(0, text.length)
    while (start < text.length && text[start].isWhitespace()) start++
    var end = start
    while (end < text.length && !text[end].isWhitespace()) end++
    if (end <= start) return null
    return base.copy(
        text = Locator.Text(
            before = (base.text.before.orEmpty() + text.substring(0, start)).takeLast(SPOKEN_CONTEXT).ifEmpty { null },
            highlight = text.substring(start, end),
            after = (text.substring(end) + base.text.after.orEmpty()).take(SPOKEN_CONTEXT).ifEmpty { null },
        ),
    )
}

private const val SENTENCE_ENDS = ".!?;:…"
private const val SENTENCE_CLOSERS = "\"'”’)]"

private fun String.endsSentenceBefore(space: Int): Boolean {
    var i = space - 1
    while (i > 0 && this[i] in SENTENCE_CLOSERS) i--
    return this[i] in SENTENCE_ENDS
}

interface NarratorAudioOutput {
    suspend fun play(audio: NarratorAudio, paused: StateFlow<Boolean>, onProgress: (Float) -> Unit)
}

class LocalNarratorSpeaker(
    private val scope: CoroutineScope,
    private val synthesize: suspend (String) -> NarratorAudio,
    private val output: NarratorAudioOutput,
    private val onStart: (String) -> Unit,
    private val onRangeStart: (String, Int) -> Unit,
    private val onDone: (String) -> Unit,
    private val onError: (String) -> Unit,
) {
    private val prepared = LinkedHashMap<String, Deferred<Result<NarratorAudio>>>()
    private var paused = MutableStateFlow(false)
    private var playback: Job? = null
    private var audio: Deferred<Result<NarratorAudio>>? = null
    private var utteranceId: String? = null
    private var started = false

    fun speak(text: String, id: String): Boolean {
        stop()
        val rendering = prepared.remove(text) ?: render(text)
        invalidate()
        val gate = MutableStateFlow(false)
        paused = gate
        audio = rendering
        utteranceId = id
        playback = scope.launch {
            try {
                val pcm = rendering.await().getOrThrow()
                gate.first { !it }
                started = true
                onStart(id)
                var reported = -1
                output.play(pcm, gate) { fraction ->
                    val start = text.wordStartAt(fraction)
                    if (start != reported) {
                        reported = start
                        scope.launch { if (utteranceId == id) onRangeStart(id, start) }
                    }
                }
                finish(id, onDone)
            } catch (_: CancellationException) {
                ensureActive()
                finish(id, onError)
            } catch (_: Exception) {
                finish(id, onError)
            }
        }
        return true
    }

    fun prepare(text: String) {
        if (text in prepared) return
        prepared[text] = render(text)
        while (prepared.size > MAX_PREPARED) prepared.remove(prepared.keys.first())?.cancel()
    }

    fun pause(): Boolean {
        if (utteranceId == null) return false
        paused.value = true
        return true
    }

    fun resume(): Boolean {
        val id = utteranceId ?: return false
        paused.value = false
        if (started) onStart(id)
        return true
    }

    fun stop() {
        playback?.cancel()
        playback = null
        audio?.cancel()
        audio = null
        utteranceId = null
        started = false
    }

    fun invalidate() {
        prepared.values.forEach { it.cancel() }
        prepared.clear()
    }

    fun release() {
        stop()
        invalidate()
    }

    private fun finish(id: String, callback: (String) -> Unit) {
        if (utteranceId != id) return
        utteranceId = null
        audio = null
        started = false
        callback(id)
    }

    private fun render(text: String): Deferred<Result<NarratorAudio>> = scope.async {
        try {
            Result.success(synthesize(text))
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            Result.failure(error)
        }
    }

    private companion object {
        const val MAX_PREPARED = 2
    }
}

private fun String.wordStartAt(fraction: Float): Int =
    lastIndexOf(' ', (fraction * length).toInt().coerceIn(0, lastIndex)) + 1

class AudioTrackNarratorOutput : NarratorAudioOutput {
    override suspend fun play(audio: NarratorAudio, paused: StateFlow<Boolean>, onProgress: (Float) -> Unit) {
        withContext(Dispatchers.IO) {
            val samples = audio.samples
            if (samples.isEmpty()) return@withContext
            val minBuffer = AudioTrack.getMinBufferSize(
                audio.sampleRate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_FLOAT,
            )
            val track = AudioTrack.Builder()
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                        .build(),
                )
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                        .setSampleRate(audio.sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                        .build(),
                )
                .setBufferSizeInBytes(maxOf(minBuffer, audio.sampleRate / 4 * Float.SIZE_BYTES))
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
            val silence = FloatArray(SILENCE_FRAMES)
            var written = 0
            var reportedAt = 0L
            try {
                if (audio.playbackSpeed != 1f) {
                    track.playbackParams = android.media.PlaybackParams().setSpeed(audio.playbackSpeed).setPitch(1f)
                }
                track.play()
                while (true) {
                    if (paused.value) {
                        track.pause()
                        paused.first { !it }
                        track.play()
                    }
                    val remaining = samples.size - written
                    val count = if (remaining > 0) {
                        track.write(samples, written, remaining, AudioTrack.WRITE_NON_BLOCKING)
                    } else {
                        track.write(silence, 0, silence.size, AudioTrack.WRITE_NON_BLOCKING)
                    }
                    check(count >= 0) { "Audio output failed ($count)" }
                    if (remaining > 0) written += count
                    val played = track.playbackHeadPosition
                    if (played >= samples.size) break
                    val now = System.nanoTime()
                    if (now - reportedAt >= PROGRESS_INTERVAL_NS) {
                        reportedAt = now
                        onProgress(played.toFloat() / samples.size)
                    }
                    delay(WRITE_INTERVAL_MS)
                }
            } finally {
                track.pause()
                track.flush()
                track.release()
            }
        }
    }

    private companion object {
        const val SILENCE_FRAMES = 1_024
        const val WRITE_INTERVAL_MS = 20L
        const val PROGRESS_INTERVAL_NS = 250_000_000L
    }
}
