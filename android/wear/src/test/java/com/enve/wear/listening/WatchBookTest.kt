package com.enve.wear.listening

import org.junit.Assert.*
import org.junit.Test
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

class WatchBookTest {
    private val book = WatchBook("account-a", "book", "Test", durationMs = 180_000,
        tracks = listOf(WatchTrack("0.audio", 0, 60_000), WatchTrack("1.audio", 60_000, 120_000)))

    @Test fun seekAcrossTrackBoundary() {
        assertEquals(TrackPosition(0, 59_999), book.locate(59_999))
        assertEquals(TrackPosition(1, 0), book.locate(60_000))
        assertEquals(TrackPosition(1, 30_000), book.locate(90_000))
    }
    @Test fun seekClampsBeforeBeginningAndAfterEnd() {
        assertEquals(TrackPosition(0, 0), book.locate(-30_000))
        assertEquals(TrackPosition(1, 120_000), book.locate(999_000))
    }
    @Test fun sameBookIdInDifferentAccountsHasDifferentStorage() {
        assertNotEquals(book.key, book.copy(account = "account-b").key)
        assertTrue(book.key.matches(Regex("[0-9a-f]{64}")))
        assertEquals(book.key, book.copy(title = "New title").key)
    }
    @Test fun offlineLibraryRoundTripsChaptersAndBookmarks() {
        val original = WatchLibrary(listOf(book.copy(downloaded = true, chapters = listOf(WatchChapter("Two", 60000, 180000)))), mapOf(book.key to WatchPosition(97000, 400, listOf(12000, 97000))))
        assertEquals(original, Json.decodeFromString<WatchLibrary>(Json.encodeToString(original)))
    }
    @Test fun serverBasePreservesReverseProxyPath() {
        assertEquals("https://example.com/books/login", WatchAbsClient.normalizeServer("https://example.com/books").resolve("login").toString())
    }
    @Test fun audioPathsPreserveReverseProxyPrefix() {
        val base = WatchAbsClient.normalizeServer("https://example.com/books")
        assertEquals("https://example.com/books/api/items/id/file/123", WatchAbsClient.resolveAudioUrl(base, "/api/items/id/file/123").toString())
    }
    @Test fun serverBaseRejectsEmbeddedSecretsAndQuery() {
        for (url in listOf("https://user:password@example.com", "https://example.com?token=test", "https://example.com/#fragment")) {
            assertThrows(IllegalArgumentException::class.java) { WatchAbsClient.normalizeServer(url) }
        }
    }

    @Test fun deliberateRewindPushesWhenServerMatchesBaseline() {
        val pending = WatchPendingProgress("account", "book", 30_000, 300, 120_000, 100)
        val remote = WatchRemoteProgress(120_000, 240_000, 100)
        assertEquals(WatchProgressSyncDecision.PUSH_LOCAL, progressSyncDecision(pending, remote))
    }

    @Test fun independentlyChangedServerProgressCreatesConflict() {
        val pending = WatchPendingProgress("account", "book", 30_000, 300, 120_000, 100)
        val remote = WatchRemoteProgress(180_000, 240_000, 200)
        assertEquals(WatchProgressSyncDecision.CONFLICT, progressSyncDecision(pending, remote))
    }

    @Test fun changedServerPositionCreatesConflictEvenWithAnUnreliableTimestamp() {
        val pending = WatchPendingProgress("account", "book", 30_000, 300, 120_000, 100)
        val remote = WatchRemoteProgress(180_000, 240_000, 50)
        assertEquals(WatchProgressSyncDecision.CONFLICT, progressSyncDecision(pending, remote))
    }

    @Test fun remoteProgressPullsOnlyWithoutLocalChanges() {
        val remote = WatchRemoteProgress(180_000, 240_000, 200)
        assertEquals(WatchProgressSyncDecision.PULL_REMOTE, progressSyncDecision(null, remote))
        assertEquals(WatchProgressSyncDecision.NOTHING, progressSyncDecision(null, null))
    }

    @Test fun matchingRemotePositionCompletesAnInterruptedPush() {
        val pending = WatchPendingProgress("account", "book", 30_000, 300, 120_000, 100)
        val remote = WatchRemoteProgress(30_500, 240_000, 400)
        assertEquals(WatchProgressSyncDecision.COMPLETE_LOCAL, progressSyncDecision(pending, remote))
    }
}
