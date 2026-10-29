package com.enve.app.storyalign.ctc

import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CtcPcmWindowStreamTest {
    @Test
    fun windowsPreserveOverlapClockAndFinalPartialWithoutReplayingOverlap() = runBlocking {
        val input = FloatArray(2_400) { it.toFloat() }
        val windows = ArrayList<CtcPcmWindow>()
        CtcPcmWindowStream.consume(1_000, 800, decode = { sink ->
            input.asList().chunked(137).forEach { sink(it.toFloatArray()) }
        }, consume = { windows.add(it) })
        assertEquals(listOf(0L, 800L, 1_600L), windows.map { it.startSample })
        assertEquals(listOf(1_000, 1_000, 800), windows.map { it.samples.size })
        windows.forEach { window ->
            assertTrue(window.samples.contentEquals(input.copyOfRange(window.startSample.toInt(), window.startSample.toInt() + window.samples.size)))
        }
    }

    @Test
    fun cancellationUnblocksDecoderWaitingWithExactlyOneWindowAhead() = runBlocking {
        withTimeout(5_000) {
            val consumed = CompletableDeferred<Unit>()
            val decoded = AtomicInteger()
            val finished = CompletableDeferred<Unit>()
            val job = async {
                CtcPcmWindowStream.consume(1_000, 800, decode = { sink ->
                    try {
                        repeat(100) {
                            decoded.incrementAndGet()
                            sink(FloatArray(1_000))
                        }
                    } finally {
                        finished.complete(Unit)
                    }
                }, consume = {
                    consumed.complete(Unit)
                    awaitCancellation()
                })
            }
            consumed.await()
            while (decoded.get() < 2) kotlinx.coroutines.yield()
            assertEquals(2, decoded.get())
            job.cancelAndJoin()
            finished.await()
            assertEquals(2, decoded.get())
        }
    }

    @Test
    fun decoderFailurePropagatesToConsumer() = runBlocking {
        val failure = IllegalStateException("Decoder failed")
        var thrown: Throwable? = null
        try {
            CtcPcmWindowStream.consume(1_000, 800, decode = { throw failure }, consume = { })
        } catch (error: IllegalStateException) {
            thrown = error
        }
        assertEquals(failure.javaClass, thrown?.javaClass)
        assertEquals(failure.message, thrown?.message)
    }

    @Test
    fun cancellationStopsDecoderEvenWhenItProducesNoPcm() = runBlocking {
        withTimeout(5_000) {
            val started = CompletableDeferred<Unit>()
            val finished = CompletableDeferred<Unit>()
            val job = async {
                CtcPcmWindowStream.consume(1_000, 800, decode = {
                    val execution = currentCoroutineContext()
                    started.complete(Unit)
                    try {
                        while (true) {
                            execution.ensureActive()
                            Thread.sleep(10)
                        }
                    } finally {
                        finished.complete(Unit)
                    }
                }, consume = { })
            }
            started.await()
            job.cancelAndJoin()
            finished.await()
        }
    }
}
