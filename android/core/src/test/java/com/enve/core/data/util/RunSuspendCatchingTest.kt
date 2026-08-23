package com.enve.core.data.util

import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class RunSuspendCatchingTest {
    @Test
    fun `returns successful result`() = runBlocking {
        assertEquals("value", runSuspendCatching { "value" }.getOrThrow())
    }

    @Test
    fun `captures ordinary exceptions`() = runBlocking {
        val failure = IOException("failed")

        assertSame(failure, runSuspendCatching<String> { throw failure }.exceptionOrNull())
    }

    @Test
    fun `rethrows cancellation`() {
        val cancellation = CancellationException("cancelled")

        assertSame(
            cancellation,
            assertThrows(CancellationException::class.java) {
                runBlocking { runSuspendCatching<Unit> { throw cancellation } }
            },
        )
    }
}
