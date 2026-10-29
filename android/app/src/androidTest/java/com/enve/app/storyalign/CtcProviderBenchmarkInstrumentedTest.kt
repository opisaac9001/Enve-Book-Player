package com.enve.app.storyalign

import android.os.Debug
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.storyalign.ctc.CtcEmissions
import com.enve.app.storyalign.ctc.QuartzNetSession
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.abs
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

class CtcProviderBenchmarkInstrumentedTest {
    @Test
    fun benchmarkProvidedPcm() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue(args.getString("ctcPcm") != null && args.getString("ctcModelDirectory") != null)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val pcm = File(checkNotNull(args.getString("ctcPcm")))
        require(pcm.length() in 2_052..(64L * 16_000 * 4) && pcm.length() % 4 == 0L)
        val buffer = ByteBuffer.wrap(pcm.readBytes()).order(ByteOrder.LITTLE_ENDIAN).asFloatBuffer()
        val samples = FloatArray(buffer.remaining()).also { buffer.get(it) }
        require(samples.all { it.isFinite() })
        val model = File(checkNotNull(args.getString("ctcModelDirectory")))
        val output = File(args.getString("ctcOutputDirectory") ?: File(context.cacheDir, "ctc-verification").absolutePath)
        assertTrue(output.isDirectory || output.mkdirs())
        val available = QuartzNetSession.availableProviderNames()
        val report = JSONObject()
            .put("runtimeVersion", QuartzNetSession.runtimeVersion)
            .put("availableProviders", JSONArray(available.toList()))
            .put("sampleCount", samples.size)
            .put("audioSeconds", samples.size / 16_000.0)
        val measurements = JSONArray()
        val benchmarkThreads = args.getString("ctcBenchmarkThreads")?.let { value ->
            value.toInt().also { require(it == 1 || it == 2) }
        }
        val benchmarkRuns = args.getString("ctcBenchmarkRuns")?.toInt() ?: 3
        require(benchmarkRuns in 1..100)
        val powerManager = checkNotNull(context.getSystemService(PowerManager::class.java))
        val profiling = args.getString("ctcOrtProfile") == "true"
        report.put("kernelProfilingEnabled", profiling)
        report.put("requestedRuns", benchmarkRuns)
        report.put("measurements", measurements)
        var reference: CtcEmissions? = null
        var signalDimension: String? = null
        val configurations = if (benchmarkThreads != null) {
            listOf(Triple(QuartzNetSession.Provider.CPU, benchmarkThreads, false))
        } else listOf(
            Triple(QuartzNetSession.Provider.CPU, 1, false),
            Triple(QuartzNetSession.Provider.XNNPACK, 1, false),
            Triple(QuartzNetSession.Provider.CPU, 2, false),
            Triple(QuartzNetSession.Provider.CPU, 1, true),
            Triple(QuartzNetSession.Provider.XNNPACK, 1, true),
        )
        for ((provider, threads, fixedShape) in configurations) {
            val measurement = JSONObject()
                .put("provider", provider.name)
                .put("intraOpThreads", threads)
                .put("staticSignalSamples", if (fixedShape) samples.size + 512 else JSONObject.NULL)
            measurements.put(measurement)
            if (provider == QuartzNetSession.Provider.XNNPACK && "XNNPACK" !in available) {
                measurement.put("available", false)
            } else {
                measurement.put("available", true)
                val creationStarted = SystemClock.elapsedRealtimeNanos()
                val profilePrefix = if (profiling) File(output, "ort-${provider.name.lowercase()}-$threads-${if (fixedShape) "static" else "dynamic"}") else null
                QuartzNetSession(
                    model, provider, threads, profilePrefix,
                    staticSignalSamples = if (fixedShape) samples.size + 512 else null,
                    signalDimensionName = if (fixedShape) checkNotNull(signalDimension) else null,
                ).use { session ->
                    measurement.put("sessionCreationMillis", elapsedMillis(creationStarted))
                    if (signalDimension == null) {
                        signalDimension = session.signalDimensionNames.last().also { require(it.isNotBlank()) }
                        report.put("signalDimensionName", signalDimension)
                    }
                    val warmupStarted = SystemClock.elapsedRealtimeNanos()
                    session.analyze(samples)
                    measurement.put("warmupMillis", elapsedMillis(warmupStarted))
                    val runs = JSONArray()
                    val cpuRuns = JSONArray()
                    val thermalStatuses = JSONArray()
                    measurement.put("inferenceMillis", runs)
                    measurement.put("processCpuMillis", cpuRuns)
                    measurement.put("thermalStatus", thermalStatuses)
                    repeat(benchmarkRuns) {
                        val cpuStarted = Process.getElapsedCpuTime()
                        val started = SystemClock.elapsedRealtimeNanos()
                        val emissions = session.analyze(samples)
                        runs.put(elapsedMillis(started))
                        cpuRuns.put(Process.getElapsedCpuTime() - cpuStarted)
                        thermalStatuses.put(if (Build.VERSION.SDK_INT >= 29) powerManager.currentThermalStatus else JSONObject.NULL)
                        if (reference == null) reference = emissions
                        measurement.put("similarityToCpu", compare(checkNotNull(reference), emissions))
                        measurement.put("nativeHeapBytes", Debug.getNativeHeapAllocatedSize())
                        File(output, "provider-benchmark.json").writeText(report.toString(2))
                    }
                    if (profiling) measurement.put("kernelProfilePath", session.endProfiling())
                }
            }
            File(output, "provider-benchmark.json").writeText(report.toString(2))
        }
    }

    private fun elapsedMillis(started: Long) = (SystemClock.elapsedRealtimeNanos() - started) / 1_000_000.0

    private fun compare(reference: CtcEmissions, actual: CtcEmissions): JSONObject {
        assertEquals(reference.frames, actual.frames)
        assertEquals(reference.classes, actual.classes)
        var sum = 0.0
        var maximum = 0.0
        var count = 0
        for (index in reference.values.indices) {
            val expected = reference.values[index]
            val value = actual.values[index]
            if (expected.isFinite() && value.isFinite()) {
                val difference = abs(expected.toDouble() - value)
                sum += difference
                maximum = maxOf(maximum, difference)
                count++
            } else {
                assertEquals(expected, value)
            }
        }
        val expectedTokens = greedy(reference)
        val actualTokens = greedy(actual)
        var previous = IntArray(actualTokens.size + 1) { it }
        var current = IntArray(actualTokens.size + 1)
        for (left in expectedTokens.indices) {
            current[0] = left + 1
            for (right in actualTokens.indices) {
                current[right + 1] = minOf(
                    previous[right + 1] + 1,
                    current[right] + 1,
                    previous[right] + if (expectedTokens[left] == actualTokens[right]) 0 else 1,
                )
            }
            val swap = previous
            previous = current
            current = swap
        }
        val distance = previous[actualTokens.size]
        return JSONObject()
            .put("meanAbsoluteLogProbabilityDifference", if (count == 0) 0.0 else sum / count)
            .put("maximumAbsoluteLogProbabilityDifference", maximum)
            .put("cpuGreedyTokenCount", expectedTokens.size)
            .put("greedyTokenCount", actualTokens.size)
            .put("greedyTokenEditDistance", distance)
            .put("greedyTokenAgreement", 1.0 - distance.toDouble() / maxOf(1, expectedTokens.size, actualTokens.size))
    }

    private fun greedy(emissions: CtcEmissions): List<Int> {
        val tokens = ArrayList<Int>()
        var previous = -1
        for (frame in 0 until emissions.frames) {
            val offset = frame * emissions.classes
            var best = 0
            for (token in 1 until emissions.classes) {
                if (emissions.values[offset + token] > emissions.values[offset + best]) best = token
            }
            if (best != previous && best != emissions.blank) tokens.add(best)
            previous = best
        }
        return tokens
    }
}
