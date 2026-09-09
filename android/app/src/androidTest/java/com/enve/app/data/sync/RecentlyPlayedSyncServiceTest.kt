package com.enve.app.data.sync

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.data.sync.ProviderSyncResult
import com.enve.core.data.sync.ProviderSyncStrategy
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RecentlyPlayedSyncServiceTest {
    @Test
    fun reportsPartialFailureAlongsideSuccessfulMerges() = runBlocking {
        val service = RecentlyPlayedSyncService(setOf(strategy("ABS") {
            ProviderSyncResult(2, 0, listOf("Audiobookshelf"))
        }))

        val result = service.syncOnLaunch()

        assertEquals(2, result.pulledItemCount)
        assertEquals(listOf("Audiobookshelf"), result.failedStrategies)
        assertTrue(result.hasFailures)
    }

    @Test
    fun cancellationStopsDispatchInsteadOfReportingFailure() = runBlocking {
        var nextCalled = false
        val cancellation = CancellationException("cancelled")
        val service = RecentlyPlayedSyncService(linkedSetOf(
            strategy("cancelled") { throw cancellation },
            strategy("next") { nextCalled = true; ProviderSyncResult.ZERO },
        ))

        val error = try {
            service.syncOnLaunch()
            null
        } catch (e: CancellationException) {
            e
        }

        assertEquals(cancellation, error)
        assertEquals(false, nextCalled)
    }

    @Test
    fun failedProviderDoesNotPreventAnotherProviderFromSyncing() = runBlocking {
        val service = RecentlyPlayedSyncService(linkedSetOf(
            strategy("failed") { error("unavailable") },
            strategy("healthy") { ProviderSyncResult(3, 1) },
        ))

        val result = service.syncOnLaunch()

        assertEquals(4, result.mergedItemCount)
        assertEquals(listOf("failed"), result.failedStrategies)
    }

    private fun strategy(name: String, block: suspend () -> ProviderSyncResult) = object : ProviderSyncStrategy {
        override val id = name
        override val displayName = name
        override suspend fun sync(force: Boolean, launchOptimized: Boolean) = block()
    }
}
