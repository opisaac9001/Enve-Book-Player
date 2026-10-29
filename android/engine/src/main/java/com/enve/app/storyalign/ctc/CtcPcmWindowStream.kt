package com.enve.app.storyalign.ctc

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.trySendBlocking
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch

internal data class CtcPcmWindow(val samples: FloatArray, val startSample: Long)

internal object CtcPcmWindowStream {
    suspend fun consume(
        windowSamples: Int,
        strideSamples: Int,
        decode: suspend ((FloatArray) -> Unit) -> Unit,
        consume: suspend (CtcPcmWindow) -> Unit,
    ) = coroutineScope {
        require(windowSamples > 512 && strideSamples in 1 until windowSamples)
        val windows = Channel<CtcPcmWindow>(Channel.RENDEZVOUS)
        val producer = launch(Dispatchers.IO) {
            val execution = currentCoroutineContext()
            val buffer = FloatArray(windowSamples)
            val overlap = windowSamples - strideSamples
            var filled = 0
            var startSample = 0L
            try {
                decode { samples ->
                    execution.ensureActive()
                    var read = 0
                    while (read < samples.size) {
                        execution.ensureActive()
                        val count = minOf(samples.size - read, buffer.size - filled)
                        samples.copyInto(buffer, filled, read, read + count)
                        read += count
                        filled += count
                        if (filled == buffer.size) {
                            windows.trySendBlocking(CtcPcmWindow(buffer.copyOf(), startSample)).getOrThrow()
                            buffer.copyInto(buffer, 0, strideSamples, windowSamples)
                            filled = overlap
                            startSample += strideSamples
                        }
                    }
                }
                if (filled > 512 && (filled > overlap || startSample == 0L)) {
                    windows.send(CtcPcmWindow(buffer.copyOf(filled), startSample))
                }
            } finally {
                windows.close()
            }
        }
        try {
            for (window in windows) consume(window)
        } finally {
            windows.cancel()
            producer.cancelAndJoin()
        }
    }
}
