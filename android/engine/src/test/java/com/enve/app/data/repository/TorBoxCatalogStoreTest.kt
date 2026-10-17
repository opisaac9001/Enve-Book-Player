package com.enve.app.data.repository

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.After
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class TorBoxCatalogStoreTest {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val catalog = TorBoxCatalogStore(scope)
    private val file = CloudAudioFile("1", "Book.m4b", "Books/Book.m4b", "Books", "https://fixture/book", 1)

    @After
    fun close() { scope.cancel() }

    @Test
    fun concurrentScreensShareApiAndFolderScanWhileApiReturnsEarly() = runBlocking {
        val apiCalls = AtomicInteger()
        val folderCalls = AtomicInteger()
        val folderGate = CompletableDeferred<Unit>()
        val complete = async(start = CoroutineStart.UNDISPATCHED) { catalog.updates.first() }
        suspend fun load() = catalog.files("account", "server", "fixture", listOf("Books"), false,
            loadApi = { apiCalls.incrementAndGet(); listOf(file) },
            loadFolders = { folderCalls.incrementAndGet(); folderGate.await(); listOf(file.copy(coverUrl = "cover")) },
        )
        val results = withTimeout(2000) { List(8) { async { load() } }.map { it.await() } }
        assertTrue(results.all { it.first == listOf(file) && it.second.isEmpty() })
        assertEquals(1, apiCalls.get())
        assertFalse(catalog.isComplete("account"))
        folderGate.complete(Unit)
        assertEquals("account", withTimeout(2000) { complete.await() })
        val duplicate = async(start = CoroutineStart.UNDISPATCHED) { withTimeoutOrNull(100) { catalog.updates.first() } }
        assertEquals("cover", load().second.single().coverUrl)
        assertEquals(1, folderCalls.get())
        assertTrue(catalog.isComplete("account"))
        assertNull(duplicate.await())
    }

    @Test
    fun folderPickerScanAlsoServesSelectedLibraries() = runBlocking {
        val apiCalls = AtomicInteger()
        val folderCalls = AtomicInteger()
        suspend fun load(roots: List<String>) = catalog.files("account", "server", "fixture", roots, true,
            loadApi = { apiCalls.incrementAndGet(); listOf(file) },
            loadFolders = { folderCalls.incrementAndGet(); listOf(file) },
        )
        load(emptyList())
        load(listOf("Books"))
        load(listOf("Books/Nested"))
        assertEquals(1, apiCalls.get())
        assertEquals(1, folderCalls.get())
    }

    @Test
    fun manualRefreshBypassesCacheOnceAndSuppressesStaleFolderUpdates() = runBlocking {
        val firstFolders = CompletableDeferred<Unit>()
        val foldersStarted = CompletableDeferred<Unit>()
        val oldCancelled = CompletableDeferred<Unit>()
        val modes = mutableListOf<Boolean>()
        catalog.files("account", "server", "fixture", emptyList(), false,
            loadApi = { modes += it; listOf(file) },
            loadFolders = { try { foldersStarted.complete(Unit); firstFolders.await(); listOf(file) } finally { oldCancelled.complete(Unit) } },
        )
        withTimeout(2000) { foldersStarted.await() }
        catalog.invalidate()
        val update = async(start = CoroutineStart.UNDISPATCHED) { catalog.updates.first() }
        val refreshed = catalog.files("account", "server", "fixture", emptyList(), true,
            loadApi = { modes += it; listOf(file.copy(name = "Fresh.m4b")) },
            loadFolders = { emptyList() },
        )
        assertEquals(listOf(false, true), modes)
        assertEquals("Fresh.m4b", refreshed.first.single().name)
        assertEquals("account", withTimeout(2000) { update.await() })
        val stale = async(start = CoroutineStart.UNDISPATCHED) { withTimeoutOrNull(100) { catalog.updates.first() } }
        firstFolders.complete(Unit)
        withTimeout(2000) { oldCancelled.await() }
        assertNull(stale.await())
    }

    @Test
    fun accountsAndChangedCredentialsNeverShareResults() = runBlocking {
        val calls = AtomicInteger()
        suspend fun load(account: String, token: String) = catalog.files(account, "server", token, emptyList(), true,
            loadApi = { calls.incrementAndGet(); listOf(file.copy(id = "$account:$token")) },
            loadFolders = { emptyList() },
        ).first.single().id
        assertEquals("a:first", load("a", "first"))
        assertEquals("b:first", load("b", "first"))
        assertEquals("a:second", load("a", "second"))
        assertEquals("a:first", load("a", "first"))
        assertEquals(3, calls.get())
    }

    @Test
    fun cancelledScreenDoesNotCancelSharedScan() = runBlocking {
        val apiStarted = CompletableDeferred<Unit>()
        val apiGate = CompletableDeferred<Unit>()
        val calls = AtomicInteger()
        suspend fun load() = catalog.files("account", "server", "fixture", emptyList(), true,
            loadApi = { calls.incrementAndGet(); apiStarted.complete(Unit); apiGate.await(); listOf(file) },
            loadFolders = { emptyList() },
        )
        val first = async { load() }
        apiStarted.await()
        first.cancelAndJoin()
        apiGate.complete(Unit)
        assertEquals(listOf(file), withTimeout(2000) { load() }.first)
        assertEquals(1, calls.get())
    }

    @Test
    fun emptyApiWaitsForWebDavOnlyBooks() = runBlocking {
        val foldersStarted = CompletableDeferred<Unit>()
        val folderGate = CompletableDeferred<Unit>()
        val result = async {
            catalog.files("account", "server", "fixture", emptyList(), false,
                loadApi = { emptyList() },
                loadFolders = { foldersStarted.complete(Unit); folderGate.await(); listOf(file) },
            )
        }
        foldersStarted.await()
        assertFalse(result.isCompleted)
        folderGate.complete(Unit)
        assertEquals(listOf(file), withTimeout(2000) { result.await() }.second)
    }
    @Test
    fun failedFolderScanCannotAuthorizePruningAndNextReadCanRecover() = runBlocking {
        try {
            catalog.files("account", "server", "fixture", emptyList(), true,
                loadApi = { listOf(file) },
                loadFolders = { throw TorBoxRequestException(503) },
            )
            fail("Expected failure")
        } catch (_: TorBoxRequestException) {
            assertFalse(catalog.isComplete("account"))
        }
        assertEquals(listOf(file), catalog.files("account", "server", "fixture", emptyList(), true,
            loadApi = { listOf(file) }, loadFolders = { emptyList() },
        ).first)
        assertTrue(catalog.isComplete("account"))
    }

    @Test
    fun invalidationCancelsObsoleteRequestAndWaitingScreenJoinsFreshScan() = runBlocking {
        val started = CompletableDeferred<Unit>()
        val cancelled = CompletableDeferred<Unit>()
        val modes = java.util.Collections.synchronizedList(mutableListOf<Boolean>())
        val result = async {
            catalog.files("account", "server", "fixture", emptyList(), true,
                loadApi = { fresh ->
                    modes += fresh
                    if (!fresh) {
                        try { started.complete(Unit); CompletableDeferred<Unit>().await() }
                        finally { cancelled.complete(Unit) }
                    }
                    listOf(file)
                },
                loadFolders = { emptyList() },
            )
        }
        started.await()
        catalog.invalidate()
        assertEquals(listOf(file), withTimeout(2000) { result.await() }.first)
        withTimeout(2000) { cancelled.await() }
        assertEquals(listOf(false, true), modes)
    }

}
