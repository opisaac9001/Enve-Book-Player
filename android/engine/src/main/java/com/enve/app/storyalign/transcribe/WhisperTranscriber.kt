package com.enve.app.storyalign.transcribe

import com.enve.app.storyalign.align.AudioFile
import com.enve.app.storyalign.align.Transcription
import com.enve.app.storyalign.align.TranscriptionBuilder
import com.enve.app.storyalign.align.TranscriptionSegment
import com.enve.app.storyalign.align.TranscriptionToken
import com.enve.app.storyalign.align.WordNormalizer
import com.enve.app.storyalign.pipeline.Transcriber
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

class WhisperTranscriber(
    private val modelPath: String,
    private val language: String,
    private val threads: Int,
    private val audioInputs: List<DecodedAudio>,
    private val normalizer: WordNormalizer = WordNormalizer(),
) : Transcriber {

    data class DecodedAudio(val audioFile: AudioFile, val pcm16kMono: FloatArray)

    override suspend fun transcribe(): Transcription = withContext(Dispatchers.Default) {
        val ctx = WhisperContext.fromFile(modelPath)
        val segments = ArrayList<TranscriptionSegment>()
        try {
            for (input in audioInputs) {
                val rc = ctx.transcribe(input.pcm16kMono, language, threads)
                check(rc == 0) { "whisper_full failed (rc=$rc)" }
                for (s in 0 until ctx.segmentCount()) {
                    val tokens = ArrayList<TranscriptionToken>()
                    for (t in 0 until ctx.tokenCount(s)) {
                        val text = ctx.tokenText(s, t)

                        if (text.isEmpty() || (text.startsWith("[") && text.endsWith("]"))) continue
                        tokens.add(TranscriptionToken(text, ctx.tokenStartSec(s, t), ctx.tokenEndSec(s, t)))
                    }
                    segments.add(
                        TranscriptionSegment(
                            text = ctx.segmentText(s),
                            start = ctx.segmentStartSec(s),
                            end = ctx.segmentEndSec(s),
                            audioFile = input.audioFile,
                            tokens = tokens,
                        ),
                    )
                }
            }
        } finally {
            ctx.release()
        }
        TranscriptionBuilder.fromSegments(segments, normalizer)
    }
}
