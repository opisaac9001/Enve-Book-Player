package com.enve.app.hearth

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.RemoteCatalogRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException

class RemoteLibraryCatalogTest {
    @Test
    fun callerCancellationJoinsCatalogCleanupWithoutRetiringProfile() = runBlocking {
        val runtimeJob = SupervisorJob()
        val runtime = CoroutineScope(runtimeJob + Dispatchers.Default)
        val entered = CompletableDeferred<Unit>()
        val cleanupEntered = CompletableDeferred<Unit>()
        val finishCleanup = CompletableDeferred<Unit>()
        val caller = launch {
            withCatalogRuntime(runtime) {
                entered.complete(Unit)
                try {
                    awaitCancellation()
                } finally {
                    withContext(NonCancellable) {
                        cleanupEntered.complete(Unit)
                        finishCleanup.await()
                    }
                }
            }
        }
        try {
            withTimeout(5_000) { entered.await() }
            caller.cancel()
            withTimeout(5_000) { cleanupEntered.await() }
            assertFalse(caller.isCompleted)
            assertTrue(runtimeJob.isActive)
            finishCleanup.complete(Unit)
            withTimeout(5_000) { caller.join() }
            assertFalse(runtimeJob.children.any())
        } finally {
            finishCleanup.complete(Unit)
            caller.cancelAndJoin()
            runtimeJob.cancelAndJoin()
        }
    }

    @Test
    fun retiringProfileCancelsCatalogAndWaitsForCleanup() = runBlocking {
        val runtimeJob = SupervisorJob()
        val runtime = CoroutineScope(runtimeJob + Dispatchers.Default)
        val entered = CompletableDeferred<Unit>()
        val cleanupEntered = CompletableDeferred<Unit>()
        val finishCleanup = CompletableDeferred<Unit>()
        val caller = launch {
            withCatalogRuntime(runtime) {
                entered.complete(Unit)
                try {
                    awaitCancellation()
                } finally {
                    withContext(NonCancellable) {
                        cleanupEntered.complete(Unit)
                        finishCleanup.await()
                    }
                }
            }
        }
        try {
            withTimeout(5_000) { entered.await() }
            runtimeJob.cancel()
            withTimeout(5_000) { cleanupEntered.await() }
            assertFalse(runtimeJob.isCompleted)
            finishCleanup.complete(Unit)
            withTimeout(5_000) {
                runtimeJob.join()
                caller.join()
            }
            assertTrue(caller.isCancelled)
        } finally {
            finishCleanup.complete(Unit)
            caller.cancelAndJoin()
            runtimeJob.cancelAndJoin()
        }
    }

    @Test
    fun retiredProfileDoesNotStartAnotherCatalogOperation() = runBlocking {
        val runtimeJob = SupervisorJob()
        val runtime = CoroutineScope(runtimeJob + Dispatchers.Default)
        runtimeJob.cancelAndJoin()
        var started = false
        val error = runCatching {
            withCatalogRuntime(runtime) { started = true }
        }.exceptionOrNull()
        assertTrue(error is CancellationException)
        assertFalse(started)
    }

    private val book = Book(
        id = "one", title = "Alice in Wonderland", author = "Lewis Carroll", source = BookSource.SILO,
        mediaType = AppMediaType.EBOOK, language = "en", categories = listOf("Fiction", "Classics"),
    )

    @Test
    fun offlineSearchRequiresAllWordsAcrossTitleAndContributors() {
        assertTrue(remoteCatalogMatches(book, RemoteCatalogRequest(search = "carroll alice")))
        assertFalse(remoteCatalogMatches(book, RemoteCatalogRequest(search = "alice detective")))
    }

    @Test
    fun offlineFacetsMatchAnySelectionWithinEachCategoryAndAllCategories() {
        val request = RemoteCatalogRequest(genres = setOf("Mystery", "Fiction"), languages = setOf("de", "EN"))
        assertTrue(remoteCatalogMatches(book, request))
        assertFalse(remoteCatalogMatches(book.copy(language = "fr"), request))
        assertFalse(remoteCatalogMatches(book.copy(categories = listOf("History")), request))
        assertFalse(remoteCatalogMatches(book.copy(language = null), request))
    }

    @Test
    fun offlineSearchFoldsDiacriticsAndTrimsValues() {
        val french = book.copy(title = "Les Misérables", language = " fr ", categories = listOf("Littérature"))
        assertTrue(remoteCatalogMatches(french, RemoteCatalogRequest(search = "miserables", languages = setOf("FR"), genres = setOf("litterature"))))
    }

    @Test
    fun offlineSearchKeepsMediaScope() {
        assertFalse(remoteCatalogMatches(book, RemoteCatalogRequest(mediaType = AppMediaType.AUDIOBOOK)))
        assertTrue(remoteCatalogMatches(book, RemoteCatalogRequest(mediaType = AppMediaType.EBOOK)))
    }

    @Test
    fun summaryRetainsLocalProgressAndKeepsNewServerLanguage() {
        val stored = book.copy(language = "de", currentTime = 123, readProgress = .4f, epubLocator = "saved", isDownloaded = true)
        val merged = overlayRemoteSummary(book, stored)
        assertEquals("en", merged.language)
        assertEquals(123L, merged.currentTime)
        assertEquals(.4f, merged.readProgress)
        assertEquals("saved", merged.epubLocator)
        assertTrue(merged.isDownloaded)
    }

    @Test
    fun sparseSummaryDoesNotDiscardStoredOfflineFilterMetadata() {
        val merged = overlayRemoteSummary(book.copy(language = null, categories = emptyList()), book)
        assertEquals("en", merged.language)
        assertEquals(listOf("Fiction", "Classics"), merged.categories)
    }

    @Test
    fun connectionFailuresUseOfflineFilesButTlsAndServerErrorsDoNot() {
        assertTrue(remoteCatalogUnavailable(UnknownHostException()))
        assertTrue(remoteCatalogUnavailable(SocketTimeoutException()))
        assertTrue(remoteCatalogUnavailable(ConnectException()))
        assertFalse(remoteCatalogUnavailable(SSLHandshakeException("certificate")))
        assertFalse(remoteCatalogUnavailable(IllegalStateException("HTTP 500")))
        assertFalse(remoteCatalogUnavailable(kotlinx.coroutines.CancellationException()))
    }
}
