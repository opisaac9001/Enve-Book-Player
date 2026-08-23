package com.enve.app.storyalign.align

data class AudioFile(
    val index: Int,
    val startTime: Double,
    val endTime: Double,
    val path: String,
) {
    val duration: Double get() = endTime - startTime
}

data class WordTimeStamp(
    val token: String,
    val start: Double,
    val end: Double,
    val audioFile: AudioFile,
    val index: Int,
    val startOffset: Int,
    val endOffset: Int,
    val isInterpolated: Boolean = false,
) {
    val absoluteStart: Double get() = audioFile.startTime + start
    val absoluteEnd: Double get() = audioFile.startTime + end
    val duration: Double get() = end - start
}

data class TranscriptionToken(
    val text: String,
    val start: Double,
    val end: Double,
)

data class TranscriptionSegment(
    val text: String,
    val start: Double,
    val end: Double,
    val audioFile: AudioFile,
    val tokens: List<TranscriptionToken>,
)

class Transcription(
    val text: String,
    val wordTimeline: List<WordTimeStamp>,
) {

    fun wordIndexAtOffset(offset: Int): Int? {
        if (wordTimeline.isEmpty()) return null
        var lo = 0
        var hi = wordTimeline.size - 1
        var best = 0
        while (lo <= hi) {
            val mid = (lo + hi) / 2
            val w = wordTimeline[mid]
            when {
                offset < w.startOffset -> { best = mid; hi = mid - 1 }
                offset > w.endOffset -> { lo = mid + 1 }
                else -> return mid
            }
        }
        return best.coerceIn(0, wordTimeline.size - 1)
    }
}

object TranscriptionBuilder {

    fun fromWords(words: List<WordTimeStamp>): Transcription {
        val sb = StringBuilder()
        val stamps = ArrayList<WordTimeStamp>(words.size)
        for ((i, w) in words.withIndex()) {
            if (i > 0) sb.append(' ')
            val startOffset = sb.length
            sb.append(w.token)
            val endOffset = sb.length
            stamps.add(w.copy(index = i, startOffset = startOffset, endOffset = endOffset))
        }
        return Transcription(sb.toString(), stamps)
    }

    fun fromSegments(segments: List<TranscriptionSegment>, normalizer: WordNormalizer): Transcription {
        val words = ArrayList<WordTimeStamp>()
        var index = 0
        for (seg in segments) {
            for (tok in seg.tokens) {
                val norm = normalizer.normalizedWord(tok.text).first.trim()
                if (norm.isEmpty()) continue
                words.add(
                    WordTimeStamp(
                        token = norm,
                        start = tok.start,
                        end = tok.end,
                        audioFile = seg.audioFile,
                        index = index++,
                        startOffset = -1,
                        endOffset = -1,
                    ),
                )
            }
        }
        return fromWords(words)
    }
}

internal fun String.voiceLength(): Double {
    var res = 0.0
    for (c in this) {
        res += when {
            c == ' ' -> 0.01
            c == ',' -> 2.0
            c == '.' || c == '!' || c == '?' -> 3.0
            c in '0'..'9' -> 3.0
            else -> 1.0
        }
    }
    return res
}
