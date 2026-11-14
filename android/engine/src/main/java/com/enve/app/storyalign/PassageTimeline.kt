package com.enve.app.storyalign

import com.enve.app.storyalign.ctc.CtcSentenceMatch
import com.enve.app.storyalign.ctc.CtcSentenceSelector
import kotlin.math.abs
import kotlin.math.floor
import kotlin.math.max
import kotlinx.serialization.Serializable

@Serializable
internal data class PassageWindow(val track: Int, val index: Int, val matches: List<CtcSentenceMatch>)

internal data class PassageTrackSpan(val index: Int, val start: Double, val duration: Double)

internal enum class PassageWindowState { PENDING, ANALYZING, FAILED, REJECTED, ANALYZED }

internal sealed interface PassageAudioResolution {
    data class Matched(val mapping: PassageMapping) : PassageAudioResolution
    data class Pause(val mapping: PassageMapping) : PassageAudioResolution
    data object Gap : PassageAudioResolution
    data class Unprepared(val state: PassageWindowState) : PassageAudioResolution
}

internal class PassageTimeline(
    private val tracks: List<PassageTrackSpan>,
    val sentences: List<PassageSentence>,
    private val textPositions: List<Double>,
    windows: List<PassageWindow>,
) {
    private class Handoff(val generation: Int, val target: Int, var remaining: Int)

    private val lock = Any()
    private val attempted = windows.associateByTo(LinkedHashMap()) { it.track to it.index }
    private val failed = HashSet<Pair<Int, Int>>()
    private var analyzing: Pair<Int, Int>? = null
    private var handoff: Handoff? = null
    private var handoffGeneration = 0
    private val total = tracks.sumOf { it.duration }
    private val order = compareBy<CtcSentenceMatch> { it.audioIndex }.thenBy { it.start }
    @Volatile private var mappings: List<CtcSentenceMatch> = select(windows) {}
    @Volatile private var bySentence: List<CtcSentenceMatch> = mappings.sortedBy { it.sentence }
    @Volatile private var presented: Pair<CtcSentenceMatch, PassageMapping>? = null

    fun windows(): List<PassageWindow> = synchronized(lock) { attempted.values.toList() }

    fun beginAnalysis(track: Int, index: Int) {
        synchronized(lock) { analyzing = track to index }
    }

    fun fail(track: Int, index: Int) {
        synchronized(lock) {
            failed.add(track to index)
            if (analyzing == track to index) analyzing = null
        }
    }

    fun record(window: PassageWindow, check: () -> Unit) {
        val snapshot = synchronized(lock) {
            attempted[window.track to window.index] = window
            failed.remove(window.track to window.index)
            attempted.values.toList()
        }
        val selected = select(snapshot, check)
        synchronized(lock) {
            mappings = selected
            bySentence = selected.sortedBy { it.sentence }
            if (analyzing == window.track to window.index) analyzing = null
        }
    }

    fun retry(time: Double) {
        synchronized(lock) {
            for (ref in windowsBetween(time - WINDOW, time + RETRY_AHEAD)) {
                failed.remove(ref)
                if (attempted[ref]?.matches?.isEmpty() == true) attempted.remove(ref)
            }
        }
    }

    fun nextWindow(position: Double, ahead: Double): Pair<Int, Int>? = synchronized(lock) {
        windowsBetween(position - WINDOW, position + ahead)
            .filter { it !in attempted && it !in failed && it != analyzing }
            .minByOrNull { (track, index) ->
                val start = tracks[track].start + index * WINDOW
                if (position >= start && position < start + WINDOW) -1.0 else abs(start - position)
            }
    }

    fun hasHandoff(): Boolean = synchronized(lock) { handoff?.let { it.remaining > 0 } == true }

    fun beginHandoff(target: PassageSentence): Int = synchronized(lock) {
        handoffGeneration++
        handoff = Handoff(handoffGeneration, target.index, HANDOFF_WINDOWS)
        handoffGeneration
    }

    fun takeHandoffWindow(): Pair<Int, Int>? {
        synchronized(lock) {
            val request = handoff?.takeIf { it.remaining > 0 } ?: return null
            val next = handoffCandidate(request)
            if (next == null) request.remaining = 0 else request.remaining--
            return next
        }
    }

    fun handoffPending(generation: Int): Boolean {
        synchronized(lock) {
            val request = handoff?.takeIf { it.generation == generation } ?: return false
            return analyzing != null || (request.remaining > 0 && handoffCandidate(request) != null)
        }
    }

    fun endHandoff(generation: Int) {
        synchronized(lock) { if (handoff?.generation == generation) handoff = null }
    }

    fun resolve(time: Double): PassageAudioResolution {
        val values = mappings
        var lower = 0
        var upper = values.size
        while (lower < upper) {
            val middle = (lower + upper) / 2
            if (tracks[values[middle].audioIndex].start + values[middle].start <= time) lower = middle + 1 else upper = middle
        }
        values.getOrNull(lower - 1)?.let { match ->
            if (time < tracks[match.audioIndex].start + match.end) return PassageAudioResolution.Matched(mapping(match))
            val next = values.getOrNull(lower)
            if (next != null && next.audioIndex == match.audioIndex && next.start - match.end <= PassageTextResolver.PAUSE_TOLERANCE) {
                return PassageAudioResolution.Pause(mapping(match))
            }
        }
        val (track, index) = windowAt(time) ?: return PassageAudioResolution.Unprepared(PassageWindowState.PENDING)
        return synchronized(lock) {
            val current = stateOf(track to index)
            val following = if (index < lastWindow(tracks[track])) stateOf(track to index + 1) else PassageWindowState.ANALYZED
            when {
                current == PassageWindowState.ANALYZING || following == PassageWindowState.ANALYZING -> PassageAudioResolution.Unprepared(PassageWindowState.ANALYZING)
                current == PassageWindowState.PENDING || following == PassageWindowState.PENDING -> PassageAudioResolution.Unprepared(PassageWindowState.PENDING)
                current == PassageWindowState.ANALYZED && following != PassageWindowState.FAILED -> PassageAudioResolution.Gap
                current == PassageWindowState.ANALYZED -> PassageAudioResolution.Unprepared(PassageWindowState.FAILED)
                else -> PassageAudioResolution.Unprepared(current)
            }
        }
    }

    fun preparationState(time: Double, pause: String?, cannotKeepUp: Boolean): PassagePreparationState = when (val resolved = resolve(time)) {
        is PassageAudioResolution.Matched -> PassagePreparationState(resolved.mapping, resolved.mapping.wordAt(time), FOLLOWING, preparing = false, cannotKeepUp = cannotKeepUp)
        is PassageAudioResolution.Pause -> PassagePreparationState(resolved.mapping, null, FOLLOWING, preparing = false, cannotKeepUp = cannotKeepUp)
        PassageAudioResolution.Gap -> PassagePreparationState(message = FOLLOWING, preparing = false, cannotKeepUp = cannotKeepUp)
        is PassageAudioResolution.Unprepared -> when (resolved.state) {
            PassageWindowState.ANALYZING -> PassagePreparationState(message = "Matching the narrated passage…", cannotKeepUp = cannotKeepUp)
            PassageWindowState.FAILED -> PassagePreparationState(message = "Couldn't analyze this part of the audiobook.", preparing = false, retryable = true)
            PassageWindowState.REJECTED -> PassagePreparationState(message = "No confident match for this part of the audiobook.", preparing = false, retryable = true)
            else -> pause?.let { PassagePreparationState(message = it, preparing = false) }
                ?: PassagePreparationState(message = "Waiting for this passage…", cannotKeepUp = cannotKeepUp)
        }
    }

    fun resolveText(href: String, quote: String, before: String?, after: String?, chapterProgression: Double?): PassageTextResolution =
        when (val found = PassageTextResolver.target(sentences, href, quote, before, after, chapterProgression)) {
            PassageTextResolver.Target.Ambiguous -> PassageTextResolution.Ambiguous
            PassageTextResolver.Target.Missing -> PassageTextResolution.Unprepared(null)
            is PassageTextResolver.Target.Found -> {
                val values = bySentence
                val position = values.binarySearchBy(found.sentence.index) { it.sentence }
                PassageTextResolver.resolve(
                    found.sentence, quote,
                    values.getOrNull(position)?.takeIf { position >= 0 }?.let(::mapping),
                    values.getOrNull(if (position >= 0) position - 1 else -position - 2)?.let(::mapping),
                    values.getOrNull(if (position >= 0) position + 1 else -position - 1)?.let(::mapping),
                )
            }
        }

    fun estimate(sentence: Int): Double {
        val values = bySentence
        val found = values.binarySearchBy(sentence) { it.sentence }
        fun startTime(match: CtcSentenceMatch) = tracks[match.audioIndex].start + match.start
        fun endTime(match: CtcSentenceMatch) = tracks[match.audioIndex].start + match.end
        fun endOf(match: CtcSentenceMatch) = textPositions.getOrElse(match.sentence + 1) { 1.0 }
        if (found >= 0) return startTime(values[found])
        val previous = values.getOrNull(-found - 2)
        val next = values.getOrNull(-found - 1)
        val at = textPositions[sentence]
        val estimate = when {
            previous != null && next != null -> {
                val span = textPositions[next.sentence] - endOf(previous)
                if (span <= 0) endTime(previous)
                else endTime(previous) + (startTime(next) - endTime(previous)) * ((at - endOf(previous)) / span).coerceIn(0.0, 1.0)
            }
            previous != null -> endTime(previous) + (at - endOf(previous)) * total
            next != null -> startTime(next) - (textPositions[next.sentence] - at) * total
            else -> at * total
        }
        return estimate.coerceIn(0.0, total)
    }

    private fun handoffCandidate(request: Handoff): Pair<Int, Int>? {
        val estimate = estimate(request.target)
        return windowsBetween(estimate - HANDOFF_RADIUS, estimate + HANDOFF_RADIUS)
            .filter { it !in attempted && it !in failed && it != analyzing }
            .minByOrNull { (track, index) ->
                val start = tracks[track].start + index * WINDOW
                if (estimate >= start && estimate < start + WINDOW) 0.0 else minOf(abs(start - estimate), abs(start + WINDOW - estimate))
            }
    }

    private fun stateOf(ref: Pair<Int, Int>): PassageWindowState = when {
        analyzing == ref -> PassageWindowState.ANALYZING
        ref in failed -> PassageWindowState.FAILED
        else -> attempted[ref]?.let { if (it.matches.isEmpty()) PassageWindowState.REJECTED else PassageWindowState.ANALYZED }
            ?: PassageWindowState.PENDING
    }

    private fun windowAt(time: Double): Pair<Int, Int>? {
        val track = tracks.lastOrNull { it.start <= time } ?: tracks.firstOrNull() ?: return null
        val local = (time - track.start).coerceIn(0.0, track.duration)
        return track.index to floor(local / WINDOW).toInt().coerceAtMost(lastWindow(track))
    }

    private fun windowsBetween(lowerTime: Double, upperTime: Double): List<Pair<Int, Int>> = tracks.flatMap { track ->
        val lower = max(0.0, lowerTime - track.start)
        val upper = minOf(track.duration, upperTime - track.start)
        if (upper <= 0 || lower >= track.duration || upper <= lower) emptyList()
        else (floor(lower / WINDOW).toInt()..minOf(lastWindow(track), floor((upper - 0.001) / WINDOW).toInt())).map { track.index to it }
    }

    private fun lastWindow(track: PassageTrackSpan) = floor((max(track.duration, 0.001) - 0.001) / WINDOW).toInt()

    private fun select(windows: Collection<PassageWindow>, check: () -> Unit) = CtcSentenceSelector.select(
        windows.flatMap(PassageWindow::matches).filter { it.audioIndex in tracks.indices && it.sentence in sentences.indices }, check,
    ).sortedWith(order)

    private fun mapping(match: CtcSentenceMatch): PassageMapping {
        presented?.let { (source, mapping) -> if (source == match) return mapping }
        val sentence = sentences[match.sentence]
        val offset = tracks[match.audioIndex].start
        fun neighbor(index: Int) = sentences.getOrNull(index)?.takeIf { it.href == sentence.href }?.text.orEmpty()
        val start = offset + match.start
        val end = offset + match.end
        val words = PassageWordTiming.validated(
            match.words.map { PassageWordTiming(it.location, it.length, offset + it.start, offset + it.end) },
            sentence.text, start, end,
        )
        return PassageMapping(match.sentence, sentence.href, sentence.text, neighbor(match.sentence - 1), neighbor(match.sentence + 1),
            sentence.chapterProgression, start, end, words).also { presented = match to it }
    }

    companion object {
        const val WINDOW = 30.0
        const val FOLLOWING = "Following audiobook"
        private const val RETRY_AHEAD = 120.0
        private const val HANDOFF_WINDOWS = 16
        private const val HANDOFF_RADIUS = 600.0
    }
}
