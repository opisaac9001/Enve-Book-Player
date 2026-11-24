package com.enve.app.data.repository

import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class CatalogRefreshLifecycleTest {
    private val foreground = MutableStateFlow(true)
    private val loader = CatalogRefreshLifecycle(
        { foreground.first { it }; Unit },
        { foreground.first { !it }; Unit },
    )

    @Test fun waitsForForegroundBeforeRequestingNextPage() = runBlocking {
        foreground.value = false
        var requests = 0
        val loading = async(start = CoroutineStart.UNDISPATCHED) {
            loader.load { requests++; Result.success(500) }
        }
        assertEquals(0, requests)
        foreground.value = true
        assertEquals(500, loading.await().getOrThrow())
        assertEquals(1, requests)
    }

    @Test fun backgroundNetworkFailureRetriesSameRequestOnReturn() = runBlocking {
        var requests = 0
        val failure = CompletableDeferred<Unit>()
        val loading = async(start = CoroutineStart.UNDISPATCHED) {
            loader.load {
                if (++requests == 1) {
                    foreground.value = false
                    failure.await()
                    Result.failure(IOException("Connection timed out"))
                } else Result.success(500)
            }
        }
        kotlinx.coroutines.yield()
        failure.complete(Unit)
        kotlinx.coroutines.yield()
        assertEquals(1, requests)
        foreground.value = true
        assertEquals(500, loading.await().getOrThrow())
        assertEquals(2, requests)
    }

    @Test fun foregroundFailuresAreReturnedWithoutRetry() = runBlocking {
        var requests = 0
        val failure = IOException("Offline")
        val result = loader.load<Int> { requests++; Result.failure(failure) }
        assertSame(failure, result.exceptionOrNull())
        assertEquals(1, requests)
    }

    @Test fun cancellationWhileBackgroundedDoesNotIssueRequest() = runBlocking {
        foreground.value = false
        var requests = 0
        val loading = async(start = CoroutineStart.UNDISPATCHED) {
            loader.load { requests++; Result.success(500) }
        }
        loading.cancelAndJoin()
        foreground.value = true
        assertTrue(loading.isCancelled)
        assertEquals(0, requests)
    }

    @Test fun requestCancellationPropagates() = runBlocking {
        var requests = 0
        val loading = async {
            loader.load<Int> { requests++; throw CancellationException() }
        }
        try {
            loading.await()
            fail("Expected cancellation")
        } catch (_: CancellationException) {
            assertEquals(1, requests)
        }
    }
}
