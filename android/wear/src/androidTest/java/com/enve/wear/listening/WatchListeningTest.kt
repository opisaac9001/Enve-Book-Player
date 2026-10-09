package com.enve.wear.listening

import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.workDataOf
import com.enve.wear.MainActivity
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class WatchListeningTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context get() = instrumentation.targetContext

    @Test fun phoneProvisioningUsesTheWatchKeyAndRejectsReplays() {
        val manager = WatchProvisioningManager(context)
        val request = manager.publishRequest()
        val connection = com.enve.wear.protocol.WearProvisionedConnection(
            connectionId = "phone-connection",
            source = "AUDIOBOOKSHELF",
            server = "https://books.example.com/",
            username = "reader",
            accessToken = "access-token",
            refreshToken = "refresh-token",
        )
        val envelope = com.enve.wear.protocol.WearProvisioningCrypto.encrypt(
            request.publicKey,
            request.requestId,
            com.enve.wear.protocol.WearProtocol.encodeProvisionedConnection(connection),
        )
        val bytes = com.enve.wear.protocol.WearProtocol.encodeProvisioningEnvelope(envelope)
        assertEquals(connection, manager.consume(bytes))

        assertThrows(WatchRequestException::class.java) { manager.consume(bytes) }
    }

    @Test fun downloadThenPlayWithoutServerAndRestorePosition() = runBlocking {
        val audio = instrumentation.context.assets.open("tone.m4a").use { it.readBytes() }
        val server = MockWebServer()
        val media = """{"id":"test-book","media":{"metadata":{"title":"Watch test book","authorName":"Enve test"},"duration":240,"chapters":[{"title":"First","start":0,"end":120},{"title":"Second","start":120,"end":240}],"tracks":[{"index":1,"contentUrl":"/audio/one","startOffset":0,"duration":120},{"index":2,"contentUrl":"/audio/two","startOffset":120,"duration":120}]}}"""
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.getHeader("Authorization") != "Bearer fixture-only") return MockResponse().setResponseCode(401)
                return when {
                    request.path == "/api/libraries" -> MockResponse().setBody("""{"libraries":[{"id":"lib","name":"Test library","mediaType":"book"}]}""")
                    request.path!!.startsWith("/api/libraries/lib/items") -> MockResponse().setBody("""{"results":[$media],"total":1}""")
                    request.path!!.startsWith("/api/items/test-book") -> MockResponse().setBody(media)
                    request.path!!.startsWith("/audio/") -> MockResponse().setHeader("Content-Type", "audio/mp4").setBody(Buffer().write(audio))
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
        val vault = CredentialVault(context)
        val api = WatchAbsClient(vault)
        val account = WatchAccount(server.url("/").toString(), "test-user", "test", "fixture-only")
        vault.write(account)
        assertEquals(account, vault.read())
        assertFalse(File(context.noBackupFilesDir, "watch-session").readText().contains("fixture-only"))
        assertEquals("Test library", api.libraries(account).single().name)
        val book = api.books(account, "lib", 0).books.single()
        val store = WatchLibraryStore.get(context)
        store.saveBook(book)
        val work = WorkManager.getInstance(context)
        val request = OneTimeWorkRequestBuilder<WatchDownloadWorker>().setInputData(workDataOf("key" to book.key)).build()
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            work.enqueue(request).result.get()
            waitFor { work.getWorkInfoById(request.id).get()?.state?.isFinished == true }
            assertEquals(WorkInfo.State.SUCCEEDED, work.getWorkInfoById(request.id).get()!!.state)
            val downloaded = store.state.value.books.first { it.key == book.key }
            assertTrue(downloaded.downloaded)
            assertEquals(2, downloaded.tracks.size)
            downloaded.tracks.forEach { track -> assertArrayEquals(audio, File(store.directory(book.key), track.path).readBytes()) }
            server.shutdown()
            fun play() = ContextCompat.startForegroundService(context, Intent(context, WatchPlaybackService::class.java)
                .setAction(WatchPlaybackService.ACTION_OPEN).putExtra("key", book.key).putExtra("speaker", true))
            play()
            waitFor { WatchPlaybackService.state.value.playing }
            val startedAt = WatchPlaybackService.state.value.positionMs
            scenario.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
            waitFor { WatchPlaybackService.state.value.positionMs >= startedAt + 8000 }
            scenario.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)
            instrumentation.runOnMainSync { WatchPlaybackService.active!!.seek(135_000); WatchPlaybackService.active!!.speed(1.5f) }
            waitFor { WatchPlaybackService.state.value.positionMs >= 135_000 }
            instrumentation.runOnMainSync { WatchPlaybackService.active!!.toggle(); WatchPlaybackService.active!!.bookmark(); WatchPlaybackService.active!!.sleep(15) }
            waitFor { !WatchPlaybackService.state.value.playing && store.state.value.positions[book.key]?.bookmarks?.isNotEmpty() == true }
            assertEquals(1.5f, WatchPlaybackService.state.value.speed)
            assertNotNull(WatchPlaybackService.state.value.sleepAt)
            context.stopService(Intent(context, WatchPlaybackService::class.java))
            waitFor { WatchPlaybackService.active == null }
            assertTrue(store.state.value.positions[book.key]!!.positionMs >= 135_000)
            play()
            waitFor { WatchPlaybackService.state.value.playing }
            assertTrue(WatchPlaybackService.state.value.positionMs >= 135_000)
            context.stopService(Intent(context, WatchPlaybackService::class.java))
            waitFor { WatchPlaybackService.active == null }
        }
        vault.clear()
        assertNull(vault.read())
        assertTrue(store.state.value.books.first { it.key == book.key }.downloaded)
    }

    @Test fun stalePositionCannotOverwriteANewerSeek() {
        val store = WatchLibraryStore.get(context)
        val key = storageKey("position-test")
        store.savePosition(key, 180000, 100)
        store.savePosition(key, 30000, 200)
        store.savePosition(key, 190000, 150)
        assertEquals(30000, store.state.value.positions[key]!!.positionMs)
    }

    @Test fun completedPushDoesNotDropNewerPlaybackProgress() {
        val store = WatchLibraryStore.get(context)
        val book = WatchBook("race-account", "race-${System.nanoTime()}", "Race", downloaded = true)
        store.saveBook(book)
        store.savePosition(book.key, 30_000, 100)
        val pushed = checkNotNull(store.state.value.pendingProgress[book.key])
        store.savePosition(book.key, 60_000, 200)
        store.completeProgressPush(book.key, pushed, WatchRemoteProgress(30_000, 120_000, 300))
        assertEquals(60_000L, store.state.value.pendingProgress[book.key]?.positionMs)
        assertEquals(30_000L, store.state.value.pendingProgress[book.key]?.baselinePositionMs)
    }


    @Test fun expiredAccessTokenRefreshesAndRotatesStoredCredentials() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val vault = CredentialVault(context)
            val account = WatchAccount(server.url("/").toString(), "phone-connection", "test", "old-access", "old-refresh")
            vault.write(account)
            server.enqueue(MockResponse().setResponseCode(401))
            server.enqueue(MockResponse().setBody("""{"user":{"id":"refresh-user","username":"test","accessToken":"new-access","refreshToken":"new-refresh"}}"""))
            server.enqueue(MockResponse().setBody("""{"libraries":[]}"""))
            assertTrue(WatchAbsClient(vault).libraries(account).isEmpty())
            val initial = server.takeRequest(2, java.util.concurrent.TimeUnit.SECONDS)!!
            val refresh = server.takeRequest(2, java.util.concurrent.TimeUnit.SECONDS)!!
            val retried = server.takeRequest(2, java.util.concurrent.TimeUnit.SECONDS)!!
            assertEquals("Bearer old-access", initial.getHeader("Authorization"))
            assertEquals("/auth/refresh", refresh.path)
            assertEquals("old-refresh", refresh.getHeader("x-refresh-token"))
            assertEquals("Bearer new-access", retried.getHeader("Authorization"))
            assertEquals("new-refresh", vault.read()!!.refreshToken)
            assertEquals("phone-connection", vault.read()!!.userId)
            vault.clear()
        }
    }

    @Test fun audioCannotSendCredentialsToAnotherOriginOrAccount() {
        MockWebServer().use { server ->
            server.start()
            val vault = CredentialVault(context)
            val account = WatchAccount(server.url("/").toString(), "one", "test", "fixture-token")
            vault.write(account)
            val api = WatchAbsClient(vault)
            assertThrows(WatchRequestException::class.java) { api.audio(account, "https://example.com/audio", 0, null) }
            assertEquals(0, server.requestCount)
            val second = account.copy(userId = "two")
            vault.write(second)
            assertEquals(2, vault.all().size)
            assertEquals(account, vault.read(account.key))
            assertFalse(vault.updateIfCurrent(account.copy(token = "stale"), account.copy(token = "stale-renewal")))
            vault.remove(account.key)
            assertThrows(WatchRequestException::class.java) { api.audio(account, "/audio", 0, null) }
            assertEquals(0, server.requestCount)
            vault.clear()
        }
    }

    @Test fun partialDownloadRemainsUnavailableAndResumesWithRange() {
        val audio = instrumentation.context.assets.open("tone.m4a").use { it.readBytes() }
        MockWebServer().use { server ->
            server.start()
            val vault = CredentialVault(context)
            val account = WatchAccount(server.url("/").toString(), "partial-user", "test", "fixture-token")
            vault.write(account)
            val book = WatchBook(account.key, "partial-book", "Interrupted test", durationMs = 120000)
            val store = WatchLibraryStore.get(context)
            store.saveBook(book)
            var requests = 0
            var resumedOffset = 0L
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    if (request.path!!.startsWith("/api/items/")) return MockResponse().setBody("""{"id":"partial-book","media":{"metadata":{"title":"Interrupted test"},"duration":120,"tracks":[{"index":1,"contentUrl":"/audio","startOffset":0,"duration":120}]}}""")
                    requests++
                    if (requests == 1) return MockResponse().setHeader("ETag", "\"test-audio\"").setBody(Buffer().write(audio)).setSocketPolicy(okhttp3.mockwebserver.SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY)
                    resumedOffset = request.getHeader("Range")!!.removePrefix("bytes=").removeSuffix("-").toLong()
                    assertEquals("\"test-audio\"", request.getHeader("If-Range"))
                    return MockResponse().setResponseCode(206).setHeader("ETag", "\"test-audio\"")
                        .setHeader("Content-Range", "bytes $resumedOffset-${audio.size - 1}/${audio.size}")
                        .setBody(Buffer().write(audio.copyOfRange(resumedOffset.toInt(), audio.size)))
                }
            }
            ActivityScenario.launch(MainActivity::class.java).use {
                val work = WorkManager.getInstance(context)
                val first = OneTimeWorkRequestBuilder<WatchDownloadWorker>().setInputData(workDataOf("key" to book.key)).build()
                work.enqueue(first).result.get()
                waitFor { work.getWorkInfoById(first.id).get()?.let { it.state == WorkInfo.State.ENQUEUED && it.runAttemptCount > 0 } == true }
                assertFalse(store.state.value.books.first { it.key == book.key }.downloaded)
                work.cancelWorkById(first.id).result.get()
                val second = OneTimeWorkRequestBuilder<WatchDownloadWorker>().setInputData(workDataOf("key" to book.key)).build()
                work.enqueue(second).result.get()
                waitFor { work.getWorkInfoById(second.id).get()!!.state.isFinished }
                assertEquals(WorkInfo.State.SUCCEEDED, work.getWorkInfoById(second.id).get()!!.state)
                assertTrue(resumedOffset > 0)
                val downloaded = store.state.value.books.first { it.key == book.key }
                assertTrue(downloaded.downloaded)
                assertArrayEquals(audio, File(store.directory(book.key), downloaded.tracks.single().path).readBytes())
            }
            vault.clear()
        }
    }

    @Test fun progressConflictRequiresChoiceBeforeRewindPushes() {
        MockWebServer().use { server ->
            server.start()
            val vault = CredentialVault(context)
            val suffix = System.nanoTime().toString()
            val account = WatchAccount(server.url("/").toString(), "sync-user-$suffix", "test", "sync-token")
            vault.write(account)
            val book = WatchBook(account.key, "sync-book-$suffix", "Sync test", durationMs = 240_000, downloaded = true)
            val store = WatchLibraryStore.get(context)
            store.saveBook(book)
            store.applyRemoteProgress(book.key, WatchRemoteProgress(120_000, 240_000, 100))
            store.savePosition(book.key, 30_000, System.currentTimeMillis() + 1_000)
            assertEquals(account, vault.read(book.account))
            assertEquals(120_000L, store.state.value.progressBaselines[book.key]?.positionMs)
            assertEquals(30_000L, store.state.value.pendingProgress[book.key]?.positionMs)
            var remotePosition = 180.0
            var remoteUpdated = 300L
            var pushedPosition: Double? = null
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    if (request.getHeader("Authorization") != "Bearer sync-token") return MockResponse().setResponseCode(401)
                    if (request.method == "PATCH") {
                        val body = kotlinx.serialization.json.Json.parseToJsonElement(request.body.readUtf8()).jsonObject
                        assertNull(body["isFinished"])
                        pushedPosition = body["currentTime"]!!.jsonPrimitive.double
                        remotePosition = checkNotNull(pushedPosition)
                        remoteUpdated = 400
                    }
                    return MockResponse().setBody("""{"currentTime":$remotePosition,"duration":240,"lastUpdate":$remoteUpdated}""")
                }
            }
            val work = WorkManager.getInstance(context)
            fun runSync() {
                val request = OneTimeWorkRequestBuilder<WatchProgressSyncWorker>()
                    .setInputData(workDataOf("book" to book.key))
                    .build()
                work.enqueue(request).result.get()
                waitFor { work.getWorkInfoById(request.id).get()!!.state.isFinished }
                assertEquals(WorkInfo.State.SUCCEEDED, work.getWorkInfoById(request.id).get()!!.state)
            }
            runSync()
            assertNull(pushedPosition)
            assertEquals(30_000, store.state.value.progressConflicts[book.key]!!.localPositionMs)
            assertEquals(180_000, store.state.value.progressConflicts[book.key]!!.remotePositionMs)
            store.acceptLocalProgress(book.key)
            runSync()
            assertEquals(30.0, pushedPosition!!, 0.001)
            assertFalse(store.state.value.pendingProgress.containsKey(book.key))
            assertFalse(store.state.value.progressConflicts.containsKey(book.key))
            assertEquals(30_000, store.state.value.progressBaselines[book.key]!!.positionMs)
            vault.clear()
        }
    }

    @Test fun grimmoryBrowseDownloadAndProgressUseTheProviderContract() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val vault = CredentialVault(context)
            var pushed: String? = null
            server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    if (request.getHeader("Authorization") != "Bearer grimmory-token") return MockResponse().setResponseCode(401)
                    return when {
                        request.path == "/api/v1/app/libraries" -> MockResponse().setBody("""[{"id":7,"name":"Audio"}]""")
                        request.path!!.startsWith("/api/v1/app/books?") -> MockResponse().setBody("""{"content":[{"id":42,"title":"Grimmory test","authors":["Enve"],"primaryFileType":"M4B"}],"hasNext":false}""")
                        request.path == "/api/v1/audiobooks/42/info" -> MockResponse().setBody("""{"bookId":"42","bookFileId":"9","title":"Grimmory test","author":"Enve","durationMs":240000,"tracks":[{"index":0,"durationMs":120000,"cumulativeStartMs":0},{"index":1,"durationMs":120000,"cumulativeStartMs":120000}],"chapters":[{"index":0,"title":"First","startTimeMs":0,"endTimeMs":120000}]}""")
                        request.path == "/api/v1/app/books/42/progress" -> MockResponse().setBody("""{"audiobookProgress":{"positionMs":30000,"trackIndex":1,"percentage":62.5,"updatedAt":"1970-01-01T00:00:00.500Z"}}""")
                        request.path == "/api/v1/books/progress" -> {
                            pushed = request.body.readUtf8()
                            MockResponse().setResponseCode(200)
                        }
                        request.path == "/api/v1/audiobooks/42/track/0/stream" -> MockResponse().setBody("audio")
                        else -> MockResponse().setResponseCode(404)
                    }
                }
            }
            val api = WatchGrimmoryClient(vault)
            val account = WatchAccount(
                server = server.url("/").toString(),
                userId = "grimmory-user",
                username = "test",
                token = "grimmory-token",
                refreshToken = "grimmory-refresh",
                source = WatchSource.GRIMMORY,
            )
            vault.write(account)
            assertEquals(WatchSource.GRIMMORY, account.source)
            assertEquals("grimmory-user", account.userId)
            assertEquals("Audio", api.libraries(account).single().name)
            val listed = api.books(account, "7", 0)
            assertEquals("Grimmory test", listed.books.single().title)
            assertFalse(listed.hasMore)
            val download = api.download(account, "42")
            assertEquals(2, download.files.size)
            assertEquals(240_000L, download.book.durationMs)
            api.audio(account, download.files.first().url, 0, null).use { assertEquals("audio", it.body!!.string()) }
            assertEquals(150_000L, api.fetchProgress(account, "42")!!.positionMs)
            api.pushProgress(account, download.book, 30_000)
            val payload = kotlinx.serialization.json.Json.parseToJsonElement(checkNotNull(pushed)).jsonObject
            assertEquals(42, payload["bookId"]!!.jsonPrimitive.content.toInt())
            val file = payload["fileProgress"]!!.jsonObject
            assertEquals("30000", file["positionData"]!!.jsonPrimitive.content)
            assertEquals("0", file["positionHref"]!!.jsonPrimitive.content)
            vault.clear()
        }
    }

    private fun waitFor(condition: () -> Boolean) {
        val end = System.currentTimeMillis() + 30000
        while (!condition() && System.currentTimeMillis() < end) Thread.sleep(100)
        assertTrue("Condition did not become true", condition())
    }
}
