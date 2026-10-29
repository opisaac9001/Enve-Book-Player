package com.enve.app.readium

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.readium.r2.shared.publication.Locator

data class EbookTTSParagraph(val text: String, val locator: Locator? = null)

data class EbookTTSState(
    val active: Boolean = false,
    val playing: Boolean = false,
    val preparing: Boolean = false,
    val paragraph: Int = 0,
)

class EbookTTSService(
    private val scope: CoroutineScope,
    private val speak: (String, String) -> Boolean,
    private val stopSpeech: () -> Unit,
    private val onNavigate: (Locator) -> Unit,
    private val onFailure: (String) -> Unit,
    private val maxInputLength: Int = 4_000,
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

    fun setReady(ready: Boolean) {
        this.ready = ready
        if (ready && _state.value.playing && contentJob?.isActive != true) speakCurrent()
    }

    fun start(nextParagraph: suspend () -> EbookTTSParagraph?) {
        stop()
        this.nextParagraph = nextParagraph
        _state.value = EbookTTSState(active = true, playing = true, preparing = true)
        loadNext()
    }

    fun pause() {
        if (!_state.value.active) return
        interrupt()
        _state.value = _state.value.copy(playing = false, preparing = false)
    }

    fun resume() {
        if (!_state.value.active || _state.value.playing) return
        _state.value = _state.value.copy(playing = true, preparing = true)
        if (contentJob?.isActive != true) {
            if (needsNext) loadNext() else speakCurrent()
        }
    }

    fun restart() {
        if (!_state.value.playing) return
        interrupt()
        if (contentJob?.isActive != true) speakCurrent()
    }

    fun previous() {
        if (!_state.value.active || contentJob?.isActive == true) return
        interrupt()
        index = (index - 1).coerceAtLeast(0)
        offset = 0
        needsNext = false
        _state.value = _state.value.copy(paragraph = index)
        if (_state.value.playing) speakCurrent()
    }

    fun next() {
        if (!_state.value.active || contentJob?.isActive == true) return
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
        _state.value = EbookTTSState()
    }

    fun onStart(id: String?) {
        if (id == null || id != utteranceId) return
        _state.value = _state.value.copy(preparing = false)
        history.getOrNull(index)?.locator?.let(onNavigate)
    }

    fun onRangeStart(id: String?, start: Int) {
        if (id == null || id != utteranceId || start !in 0 until spokenLength) return
        offset = spokenOffset + start
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
        var end = (offset + maxInputLength).coerceAtMost(paragraph.text.length)
        if (end < paragraph.text.length) {
            val whitespace = paragraph.text.lastIndexOf(' ', end - 1)
            end = when {
                whitespace > offset + maxInputLength / 2 -> whitespace + 1
                paragraph.text[end - 1].isHighSurrogate() -> end - 1
                else -> end
            }
        }
        spokenOffset = offset
        spokenLength = end - offset
        val id = "enve-tts-${++sequence}"
        utteranceId = id
        _state.value = _state.value.copy(preparing = true)
        if (!speak(paragraph.text.substring(offset, end), id)) onError(id)
    }

    private fun loadNext() {
        val load = nextParagraph ?: return
        needsNext = true
        val session = generation
        _state.value = _state.value.copy(preparing = _state.value.playing)
        contentJob = scope.launch {
            try {
                var paragraph: EbookTTSParagraph?
                do {
                    paragraph = load()
                } while (paragraph != null && paragraph.text.isBlank())
                if (session != generation) return@launch
                contentJob = null
                if (paragraph == null) {
                    val wasEmpty = history.isEmpty()
                    stop()
                    if (wasEmpty) onFailure("No readable text was found here.")
                    return@launch
                }
                history += paragraph
                needsNext = false
                index = history.lastIndex
                offset = 0
                _state.value = _state.value.copy(paragraph = index)
                if (_state.value.playing) speakCurrent()
            } catch (error: CancellationException) {
                throw error
            } catch (_: Exception) {
                if (session != generation) return@launch
                contentJob = null
                fail("Couldn't load this passage. Try starting read back again.")
            }
        }
    }

    private fun fail(message: String) {
        pause()
        onFailure(message)
    }
}
