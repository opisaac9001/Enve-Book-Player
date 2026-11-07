package com.enve.app.readium.narrator

import android.content.Context
import com.k2fsa.sherpa.onnx.GenerationConfig
import com.k2fsa.sherpa.onnx.OfflineTts
import com.k2fsa.sherpa.onnx.OfflineTtsConfig
import com.k2fsa.sherpa.onnx.OfflineTtsKokoroModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsPocketModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsSupertonicModelConfig
import com.k2fsa.sherpa.onnx.WaveData
import com.k2fsa.sherpa.onnx.WaveReader
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.job
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.atomic.AtomicInteger

class LocalNarratorRuntime(context: Context) {
    private val store = NarratorPackStore(context.applicationContext)
    private val engineLock = Mutex()
    private val epochs = NarratorPack.entries.associateWith { AtomicInteger() }
    private var engine: Engine? = null

    fun isInstalled(pack: NarratorPack): Boolean = store.isInstalled(pack)

    suspend fun install(pack: NarratorPack, onProgress: (Float) -> Unit) = store.install(pack, onProgress)

    suspend fun remove(pack: NarratorPack) {
        unload(pack)
        store.remove(pack)
        unload(pack)
    }

    suspend fun synthesize(
        pack: NarratorPack,
        voice: String,
        text: String,
        language: String,
        speed: Float,
    ): NarratorAudio {
        val voiceIndex = pack.voices.indexOf(voice)
        require(voiceIndex >= 0) { "${pack.title} has no voice \"$voice\"" }
        val languageCode = pack.languageCode(language)
        require(text.isNotBlank() && text.length <= MAX_TEXT_LENGTH) {
            "Narration text must contain 1 to $MAX_TEXT_LENGTH characters"
        }
        require(speed.isFinite() && speed > 0f) { "Narration speed must be positive" }
        check(store.isInstalled(pack)) { "${pack.title} is not installed" }

        val generation = Generation(pack, currentCoroutineContext().job)
        return engineLock.withLock {
            withContext(Dispatchers.IO) {
                if (!generation.isCurrent) throw CancellationException("${pack.title} narration stopped")
                val loaded = engineFor(pack)
                val config = loaded.generationConfig(text, pack.speakerIds[voiceIndex], languageCode, speed)
                    ?: return@withContext NarratorAudio(FloatArray(0), loaded.tts.sampleRate())
                val audio = loaded.tts.generateWithConfigAndCallback(text, config, generation)
                if (!generation.isCurrent) throw CancellationException("${pack.title} narration stopped")
                check(audio.samples.isNotEmpty()) { "${pack.title} produced no audio" }
                NarratorAudio(audio.samples, audio.sampleRate, if (pack == NarratorPack.POCKET) speed else 1f)
            }
        }
    }

    suspend fun close() = withContext(NonCancellable) { unload(null) }

    private suspend fun unload(pack: NarratorPack?) {
        epochs.forEach { (candidate, epoch) -> if (pack == null || candidate == pack) epoch.incrementAndGet() }
        engineLock.withLock {
            val loaded = engine
            if (loaded != null && (pack == null || loaded.pack == pack)) {
                engine = null
                loaded.close()
            }
        }
    }

    private suspend fun engineFor(pack: NarratorPack): Engine {
        engine?.let { loaded ->
            if (loaded.pack == pack) return loaded
            engine = null
            loaded.close()
        }
        return store.useInstalled(pack) { directory -> Engine.open(pack, directory) }.also { engine = it }
    }

    private inner class Generation(private val pack: NarratorPack, private val job: Job) : (FloatArray) -> Int {
        private val epoch = epochs.getValue(pack).get()

        val isCurrent: Boolean get() = job.isActive && epochs.getValue(pack).get() == epoch

        override fun invoke(samples: FloatArray): Int = if (isCurrent) 1 else 0
    }

    private class Engine(
        val pack: NarratorPack,
        val tts: OfflineTts,
        private val reference: WaveData?,
        private val frontend: KokoroEnglishFrontend?,
    ) : AutoCloseable {
        override fun close() {
            try {
                tts.release()
            } finally {
                frontend?.close()
            }
        }

        fun generationConfig(text: String, speakerId: Int, language: String, speed: Float): GenerationConfig? = when (pack) {
            NarratorPack.KOKORO -> kokoroSentences(checkNotNull(frontend).phonemes(text))
                .takeIf { it.isNotEmpty() }
                ?.let { GenerationConfig(sid = speakerId, speed = speed, phonemeCodepoints = it) }
            NarratorPack.SUPERTONIC -> GenerationConfig(sid = speakerId, speed = speed, extra = mapOf("lang" to language))
            NarratorPack.POCKET -> {
                val voice = checkNotNull(reference)
                GenerationConfig(
                    referenceAudio = voice.samples,
                    referenceSampleRate = voice.sampleRate,
                    extra = mapOf("temperature" to "0.7"),
                )
            }
        }

        companion object {
            fun open(pack: NarratorPack, directory: File): Engine {
                val threads = Runtime.getRuntime().availableProcessors().coerceAtMost(4)
                val reference = if (pack == NarratorPack.POCKET) WaveReader.readWave(File(directory, POCKET_VOICE).absolutePath) else null
                val frontend = if (pack == NarratorPack.KOKORO) KokoroEnglishFrontend(directory) else null
                try {
                    val tts = OfflineTts(config = OfflineTtsConfig(model = pack.modelConfig(directory, threads)))
                    return Engine(pack, tts, reference, frontend)
                } catch (failure: Throwable) {
                    frontend?.close()
                    throw failure
                }
            }
        }
    }
}

internal fun kokoroSentences(phonemes: IntArray): Array<IntArray> {
    if (phonemes.none { Character.isLetter(it) }) return emptyArray()
    val sentences = mutableListOf<IntArray>()
    var start = 0
    while (start < phonemes.size) {
        val limit = (start + 500).coerceAtMost(phonemes.size)
        var end = limit
        if (limit < phonemes.size) {
            val tail = limit - 1 downTo start
            val boundary = tail.firstOrNull { phonemes[it].toChar() in ".!?…" }
                ?: tail.firstOrNull { phonemes[it] == ' '.code }
            if (boundary != null) end = boundary + 1
        }
        sentences += phonemes.copyOfRange(start, end)
        start = end
    }
    return sentences.toTypedArray()
}

internal fun NarratorPack.modelConfig(directory: File, threads: Int): OfflineTtsModelConfig {
    fun path(name: String) = File(directory, name).absolutePath
    return when (this) {
        NarratorPack.KOKORO -> OfflineTtsModelConfig(
            kokoro = OfflineTtsKokoroModelConfig(
                model = path("model.int8.onnx"),
                voices = path("voices.bin"),
                tokens = path("tokens.txt"),
            ),
            numThreads = threads,
        )
        NarratorPack.SUPERTONIC -> OfflineTtsModelConfig(
            supertonic = OfflineTtsSupertonicModelConfig(
                durationPredictor = path("duration_predictor.int8.onnx"),
                textEncoder = path("text_encoder.int8.onnx"),
                vectorEstimator = path("vector_estimator.int8.onnx"),
                vocoder = path("vocoder.int8.onnx"),
                ttsJson = path("tts.json"),
                unicodeIndexer = path("unicode_indexer.bin"),
                voiceStyle = path("voice.bin"),
            ),
            numThreads = threads,
        )
        NarratorPack.POCKET -> OfflineTtsModelConfig(
            pocket = OfflineTtsPocketModelConfig(
                lmFlow = path("lm_flow.int8.onnx"),
                lmMain = path("lm_main.int8.onnx"),
                encoder = path("encoder.onnx"),
                decoder = path("decoder.int8.onnx"),
                textConditioner = path("text_conditioner.onnx"),
                vocabJson = path("vocab.json"),
                tokenScoresJson = path("token_scores.json"),
            ),
            numThreads = threads,
        )
    }
}

private const val MAX_TEXT_LENGTH = 4_000
