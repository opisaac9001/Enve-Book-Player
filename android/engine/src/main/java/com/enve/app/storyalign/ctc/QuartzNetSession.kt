package com.enve.app.storyalign.ctc

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtProvider
import ai.onnxruntime.OrtSession
import ai.onnxruntime.TensorInfo
import java.io.File
import java.nio.FloatBuffer
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

class QuartzNetSession(
    directory: File,
    provider: Provider = Provider.CPU,
    intraOpThreads: Int = 2,
    profilingPrefix: File? = null,
    staticSignalSamples: Int? = null,
    signalDimensionName: String? = null,
) : AutoCloseable {
    enum class Provider { CPU, XNNPACK }
    private val environment = OrtEnvironment.getEnvironment()
    private val config = CONFIG_JSON
        .decodeFromString<Configuration>(File(directory, "config.json").readText())
    private val session: OrtSession

    init {
        require(config.sampleRate == 16_000 && config.samplesPerFrame == 320 && config.blank == 28 && config.classes == 29)
        require(intraOpThreads > 0)
        session = OrtSession.SessionOptions().use { options ->
            options.setIntraOpNumThreads(intraOpThreads)
            options.setInterOpNumThreads(1)
            options.setMemoryPatternOptimization(false)
            profilingPrefix?.let { options.enableProfiling(it.absolutePath) }
            staticSignalSamples?.let { samples ->
                require(samples > 512 && !signalDimensionName.isNullOrBlank())
                options.setSymbolicDimensionValue(signalDimensionName, samples.toLong())
            }
            if (provider == Provider.XNNPACK) {
                require(OrtProvider.XNNPACK in OrtEnvironment.getAvailableProviders()) { "XNNPACK is unavailable" }
                options.addXnnpack(mapOf("intra_op_num_threads" to intraOpThreads.toString()))
            }
            environment.createSession(File(directory, "model.onnx").absolutePath, options)
        }
        require(session.inputNames == setOf("signal")) { "Unsupported QuartzNet input graph" }
    }

    val signalDimensionNames: List<String>
        get() = (checkNotNull(session.inputInfo["signal"]).info as TensorInfo).dimensionNames.toList()

    fun analyze(samples: FloatArray): CtcEmissions {
        require(samples.size > 512 && samples.all { it.isFinite() })
        val padded = prepareSignal(samples)
        OnnxTensor.createTensor(environment, FloatBuffer.wrap(padded), longArrayOf(1, 1, padded.size.toLong())).use { input ->
            session.run(mapOf("signal" to input)).use { result ->
                val tensor = result[0] as OnnxTensor
                val shape = tensor.info.shape
                require(shape.size == 3 && shape[0] == 1L && shape[2] == config.classes.toLong()) { "Invalid QuartzNet output" }
                val buffer = checkNotNull(tensor.floatBuffer) { "QuartzNet output is not float32" }
                val values = FloatArray(buffer.remaining())
                buffer.get(values)
                CtcForcedAligner.foldSpaceIntoBlank(values, config.classes, config.blank, 0)
                return CtcEmissions(values, shape[1].toInt(), config.classes, config.blank, config.samplesPerFrame.toDouble() / config.sampleRate)
            }
        }
    }

    override fun close() = session.close()

    fun endProfiling(): String = session.endProfiling()

    @Serializable
    private data class Configuration(val sampleRate: Int, val samplesPerFrame: Int, val blank: Int, val classes: Int)

    companion object {
        private val CONFIG_JSON = Json { ignoreUnknownKeys = true }

        val runtimeVersion: String get() = OrtEnvironment.getEnvironment().version

        fun availableProviderNames(): Set<String> = OrtEnvironment.getAvailableProviders().map { it.toString() }.toSet()

        internal fun prepareSignal(samples: FloatArray): FloatArray {
            require(samples.size > 512)
            val pad = 256
            val result = FloatArray(samples.size + pad * 2)
            result[pad] = samples[0]
            for (index in 1 until samples.size) result[pad + index] = samples[index] - 0.97f * samples[index - 1]
            for (offset in 1..pad) {
                result[pad - offset] = result[pad + offset]
                result[pad + samples.size - 1 + offset] = result[pad + samples.size - 1 - offset]
            }
            return result
        }
    }
}
