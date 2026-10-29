package com.enve.app.storyalign.audio

import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.random.Random
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertSame
import org.junit.Test

class AudioConversionTest {
    @Test
    fun monoPcmExtremesAndOffsetMatchSignedSixteenBitNormalization() {
        val samples = shortArrayOf(Short.MIN_VALUE, -1, 0, 1, Short.MAX_VALUE)
        for (order in listOf(ByteOrder.LITTLE_ENDIAN, ByteOrder.BIG_ENDIAN)) {
            val buffer = ByteBuffer.allocateDirect(32).order(order)
            buffer.position(6)
            samples.forEach { buffer.putShort(it) }
            assertBitsEqual(
                floatArrayOf(-1f, -1f / 32768, 0f, 1f / 32768, 32767f / 32768),
                toMono16k(buffer, 6, samples.size * 2, 1, LinearResampler(16_000, 16_000)),
            )
        }
    }

    @Test
    fun stereoMixPreservesHalfIntegerAveragesAndIgnoresIncompleteFrame() {
        val buffer = ByteBuffer.allocateDirect(40).order(ByteOrder.LITTLE_ENDIAN)
        buffer.position(4)
        shortArrayOf(Short.MIN_VALUE, Short.MAX_VALUE, -1, 0, 1, 0, Short.MIN_VALUE, Short.MIN_VALUE, 50).forEach { buffer.putShort(it) }
        assertBitsEqual(
            floatArrayOf(-0.5f / 32768, -0.5f / 32768, 0.5f / 32768, -1f),
            toMono16k(buffer, 4, 18, 2, LinearResampler(16_000, 16_000)),
        )
    }

    @Test
    fun fragmentedAwkwardRatesMatchThePreviousScalarResamplerBitForBit() {
        val random = Random(482)
        val input = FloatArray(12_007) { random.nextInt(-32_768, 32_768) / 32768f }
        for (sourceRate in listOf(8_000, 11_025, 16_000, 22_050, 44_100, 48_000, 96_000)) {
            val actual = LinearResampler(sourceRate, 16_000)
            val baseline = ScalarBaseline(sourceRate, 16_000)
            var offset = 0
            val fragmentSizes = listOf(1, 2, 137, 1_024, 0, 513, 7, 2_049)
            var fragment = 0
            while (offset < input.size) {
                val count = minOf(fragmentSizes[fragment++ % fragmentSizes.size], input.size - offset)
                val chunk = input.copyOfRange(offset, offset + count)
                assertBitsEqual(baseline.resample(chunk), actual.resample(chunk))
                offset += count
            }
        }
    }

    @Test
    fun equalRateRetainsTheOriginalArrayIncludingEmptyChunks() {
        val resampler = LinearResampler(16_000, 16_000)
        for (input in listOf(floatArrayOf(), floatArrayOf(-0f, 0.1234567f, -1f, 1f))) {
            assertSame(input, resampler.resample(input))
        }
    }

    @Test
    fun interpolationAcrossChunkBoundaryRetainsCarryAndFractionalPhase() {
        val resampler = LinearResampler(24_000, 16_000)
        assertBitsEqual(floatArrayOf(0f, 1.5f), resampler.resample(floatArrayOf(0f, 1f, 2f)))
        assertBitsEqual(floatArrayOf(4f), resampler.resample(floatArrayOf(3f, 4f, 5f)))
        assertBitsEqual(floatArrayOf(6.5f), resampler.resample(floatArrayOf(6f, 7f, 8f)))
    }

    private fun assertBitsEqual(expected: FloatArray, actual: FloatArray) {
        assertArrayEquals(expected.map { it.toRawBits() }.toIntArray(), actual.map { it.toRawBits() }.toIntArray())
    }

    private class ScalarBaseline(sourceRate: Int, destinationRate: Int) {
        private val ratio = sourceRate.toDouble() / destinationRate
        private var position = 0.0
        private var carry: Float? = null

        fun resample(input: FloatArray): FloatArray {
            if (ratio == 1.0) return input
            if (input.isEmpty()) return input
            val previous = carry
            val source = if (previous == null) input else floatArrayOf(previous) + input
            val base = if (previous == null) 0.0 else 1.0
            val result = mutableListOf<Float>()
            var cursor = position
            while (cursor + base < source.size - 1) {
                val index = cursor + base
                val lower = index.toInt()
                val fraction = index - lower
                result.add(source[lower] * (1 - fraction).toFloat() + source[lower + 1] * fraction.toFloat())
                cursor += ratio
            }
            position = cursor + base - (source.size - 1)
            carry = source.last()
            return result.toFloatArray()
        }

    }
}
