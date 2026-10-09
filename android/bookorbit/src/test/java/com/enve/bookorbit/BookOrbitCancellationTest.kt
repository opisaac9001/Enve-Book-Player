package com.enve.bookorbit

import com.enve.bookorbit.api.BookOrbitApi
import java.io.IOException
import java.lang.reflect.Proxy
import kotlin.coroutines.Continuation
import kotlin.coroutines.intrinsics.COROUTINE_SUSPENDED
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Test

class BookOrbitCancellationTest {
    @Test
    fun cancelledDashboardAndAchievementsPropagateCancellation() {
        val cancellation = CancellationException("cancelled")
        val repository = BookOrbitInsightsRepository(failingApi(cancellation))
        assertEquals(cancellation.message, assertThrows(CancellationException::class.java) {
            runBlocking { repository.getDashboard(30) }
        }.message)
        assertSame(cancellation, assertThrows(CancellationException::class.java) {
            runBlocking { repository.getAchievements() }
        })
    }

    @Test
    fun cancelledAnnotationOperationsPropagateCancellation() {
        val cancellation = CancellationException("cancelled")
        val repository = BookOrbitAnnotationHubRepository(failingApi(cancellation))
        val operations: List<suspend () -> Any> = listOf(
            { repository.list(BookOrbitAnnotationHubFilter()) },
            { repository.books(false, null) },
            { repository.restore(1) },
            { repository.purge(1) },
            { repository.trash(listOf(1)) },
            { repository.restoreAll(listOf(1)) },
            { repository.export(BookOrbitAnnotationHubFilter(), "json") },
        )
        operations.forEach { operation ->
            assertSame(cancellation, assertThrows(CancellationException::class.java) {
                runBlocking { operation() }
            })
        }
    }

    @Test
    fun ordinaryNetworkFailuresRemainResults() = runBlocking {
        val failure = IOException("unreachable")
        val api = failingApi(failure)
        assertSame(failure, BookOrbitInsightsRepository(api).getAchievements().exceptionOrNull())
        assertSame(failure, BookOrbitAnnotationHubRepository(api).restore(1).exceptionOrNull())
    }

    private fun failingApi(failure: Exception): BookOrbitApi = Proxy.newProxyInstance(
        BookOrbitApi::class.java.classLoader,
        arrayOf(BookOrbitApi::class.java),
    ) { _, _, arguments ->
        @Suppress("UNCHECKED_CAST")
        val continuation = arguments.last() as Continuation<Any?>
        continuation.resumeWith(Result.failure(failure))
        COROUTINE_SUSPENDED
    } as BookOrbitApi
}
