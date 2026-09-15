package com.enve.app.viewmodel

import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.ReaderEngineKind
import java.io.IOException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReaderCheckpointSyncTest {
    private val first = EpubBridgeCheckpoint(
        publicationSha256 = "test-publication",
        providerFileId = "34",
        revision = 7,
        writerEpoch = 2,
        observedAt = 100_000,
        sourceEngine = ReaderEngineKind.FOLIATE,
        href = "chapter.xhtml",
        epubCfi = "epubcfi(/6/8!/4,/272/1:78,/274/1:119)",
        totalProgression = 0.42249730587516554,
    )
    private val second = first.copy(
        observedAt = 120_000,
        epubCfi = "epubcfi(/6/8!/4/276,/1:0,/1:144)",
        totalProgression = 0.4226763489964478,
    )

    @Test
    fun differentNewerCfiWinsInsideFormerEchoWindow() {
        val remote = first.copy(observedAt = 157_617)
        assertEquals(remote, select(second, remote))
    }

    @Test
    fun differentNewerCfiWinsAtIdenticalPercentage() {
        val remote = first.copy(observedAt = 130_000, totalProgression = second.totalProgression)
        assertEquals(remote, select(second, remote))
    }

    @Test
    fun differentNewerCfiWinsOutsideFormerEchoWindow() {
        val remote = first.copy(observedAt = 209_632)
        assertEquals(remote, select(second, remote))
    }

    @Test
    fun matchingCfiPreservesLocalPortableAnchor() {
        val remote = first.copy(observedAt = 130_000, href = null, revision = 0)
        assertEquals(first.copy(observedAt = 130_000), select(first, remote))
    }

    @Test
    fun olderRemoteDoesNotReplaceNewerLocal() {
        assertEquals(second, select(second, first))
    }

    @Test
    fun preciseCheckpointWinsTimestampTie() {
        assertEquals(first, select(first.copy(epubCfi = null), first))
    }

    @Test
    fun noCandidatesHasNoCheckpoint() {
        assertNull(selectCheckpointCandidate(emptyList()))
    }

    @Test
    fun smallPageTurnAndIdenticalPercentageCfiChangesAreUploaded() = runBlocking {
        val sync = FoliateCheckpointSync()
        val uploaded = mutableListOf<String?>()
        val checkpoints = listOf(first, second, first.copy(totalProgression = second.totalProgression))
        for (checkpoint in checkpoints) {
            sync.submit(checkpoint)
            sync.flush(::commit, { _, _ -> }) {
                uploaded += it.epubCfi
                Result.success(Unit)
            }
            assertFalse(sync.hasPending)
        }
        assertEquals(checkpoints.map { it.epubCfi }, uploaded)
    }

    @Test
    fun failedUploadRemainsPendingForCloseFlush() = runBlocking {
        val sync = FoliateCheckpointSync()
        sync.submit(second)
        sync.flush(::commit, { _, _ -> }) { Result.failure(IOException("offline")) }
        assertTrue(sync.hasPending)
        var retried: EpubBridgeCheckpoint? = null
        sync.flush(::commit, { _, _ -> }) {
            retried = it
            Result.success(Unit)
        }
        assertEquals(second.epubCfi, retried?.epubCfi)
        assertEquals(second.revision + 2, retried?.revision)
        assertFalse(sync.hasPending)
    }

    @Test
    fun closeFlushDoesNotWaitForDebounce() = runBlocking {
        val sync = FoliateCheckpointSync()
        sync.submit(first)
        sync.submit(second)
        val uploaded = mutableListOf<String?>()
        sync.flush(::commit, { _, _ -> }) {
            uploaded += it.epubCfi
            Result.success(Unit)
        }
        sync.flush(::commit, { _, _ -> }) {
            uploaded += it.epubCfi
            Result.success(Unit)
        }
        assertEquals(listOf(second.epubCfi), uploaded)
    }

    @Test
    fun closingScopeDoesNotCancelStartedFinalUpload() = runBlocking {
        val sync = FoliateCheckpointSync()
        val finishRequest = CompletableDeferred<Unit>()
        var uploaded = false
        sync.submit(second)
        val job = launch(start = CoroutineStart.UNDISPATCHED) {
            sync.flush(::commit, { _, _ -> }) {
                finishRequest.await()
                uploaded = true
                Result.success(Unit)
            }
        }
        job.cancel()
        finishRequest.complete(Unit)
        job.join()
        assertTrue(uploaded)
        assertFalse(sync.hasPending)
    }

    @Test
    fun pageTurnDuringCommitKeepsNewAnchorAndAdvancesItsRevision() = runBlocking {
        val sync = FoliateCheckpointSync()
        sync.submit(first)
        sync.flush(
            commit = {
                sync.submit(second)
                commit(it)
            },
            onCommitted = { _, _ -> },
            push = { Result.success(Unit) },
        )
        assertTrue(sync.hasPending)
        var nextCommit: EpubBridgeCheckpoint? = null
        sync.flush(
            commit = { nextCommit = it; commit(it) },
            onCommitted = { _, _ -> },
            push = { Result.success(Unit) },
        )
        assertEquals(second.epubCfi, nextCommit?.epubCfi)
        assertEquals(first.revision + 1, nextCommit?.revision)
        assertFalse(sync.hasPending)
    }

    @Test
    fun pageTurnDuringUploadIsNotAcknowledgedByOlderRequest() = runBlocking {
        val sync = FoliateCheckpointSync()
        sync.submit(first)
        sync.flush(::commit, { _, _ -> }) {
            sync.submit(second.copy(revision = it.revision))
            Result.success(Unit)
        }
        assertTrue(sync.hasPending)
    }

    @Test
    fun rejectedCheckpointIsNotUploaded() = runBlocking {
        val sync = FoliateCheckpointSync()
        sync.submit(first)
        sync.flush({ null }, { _, _ -> }) { error("Stale lease must not upload") }
        assertTrue(sync.hasPending)
    }

    @Test
    fun newSessionDoesNotUploadPreviousPendingCheckpoint() = runBlocking {
        val sync = FoliateCheckpointSync()
        sync.submit(first)
        sync.reset()
        sync.flush(::commit, { _, _ -> }) { error("No user movement in the new session") }
        assertFalse(sync.hasPending)
    }

    private fun select(local: EpubBridgeCheckpoint, remote: EpubBridgeCheckpoint) =
        selectCheckpointCandidate(
            listOf(
                CheckpointCandidate(local, local.observedAt, local = true),
                CheckpointCandidate(remote, remote.observedAt),
            ),
        )

    private fun commit(checkpoint: EpubBridgeCheckpoint) =
        checkpoint.copy(revision = checkpoint.revision + 1)
}
