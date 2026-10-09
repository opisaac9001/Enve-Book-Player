package com.enve.core.data.sync

import com.enve.core.data.model.BookSource
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class AudiobookProgressWriteCoordinatorTest {
    @Test
    fun providerNestedInsideEngineDoesNotDeadlock() = runBlocking {
        val coordinator = AudiobookProgressWriteCoordinator()
        withTimeout(1000L) {
            assertEquals(42, coordinator.ordered(BookSource.AUDIOBOOKSHELF, "a") {
                coordinator.ordered(BookSource.AUDIOBOOKSHELF, "a") { 42 }
            })
        }
    }

    @Test
    fun batchHistoryUploadSerializesAllBooksOnSameConnection() = runBlocking {
        val coordinator = AudiobookProgressWriteCoordinator()
        val release = CompletableDeferred<Unit>()
        val order = mutableListOf<String>()
        val upload = async(start = CoroutineStart.UNDISPATCHED) {
            coordinator.ordered(BookSource.AUDIOBOOKSHELF, "a") { order += "history"; release.await() }
        }
        val push = async(start = CoroutineStart.UNDISPATCHED) {
            coordinator.ordered(BookSource.AUDIOBOOKSHELF, "a") { order += "book" }
        }
        assertFalse(push.isCompleted)
        coordinator.ordered(BookSource.AUDIOBOOKSHELF, "b") { order += "other account" }
        coordinator.ordered(BookSource.SILO, "a") { order += "other source" }
        release.complete(Unit)
        upload.await()
        push.await()
        assertEquals(listOf("history", "other account", "other source", "book"), order)
    }
}
