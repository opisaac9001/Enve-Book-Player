package com.enve.app.viewmodel

import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.ReaderEngineKind
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ReaderOpenCheckpointAuthorityTest {

    private val localCheckpoint = EpubBridgeCheckpoint(
        publicationSha256 = "test-publication",
        providerFileId = "34",
        revision = 7,
        writerEpoch = 2,
        observedAt = 120_000,
        sourceEngine = ReaderEngineKind.FOLIATE,
        href = "chapter.xhtml",
        epubCfi = "epubcfi(/6/8!/4/276,/1:0,/1:144)",
        totalProgression = 0.4226763489964478,
    )

    private val remoteCheckpoint = localCheckpoint.copy(
        observedAt = 180_000,
        epubCfi = "epubcfi(/6/8!/4,/272/1:78,/274/1:119)",
        totalProgression = 0.6,
    )

    private val launcherCheckpoint = EpubBridgeCheckpoint(
        publicationSha256 = "test-publication",
        providerFileId = "34",
        writerEpoch = 2,
        observedAt = 90_000,
        sourceEngine = ReaderEngineKind.FOLIATE,
        href = "chapter.xhtml",
        totalProgression = 0.40,
    )

    private val local = CheckpointCandidate(localCheckpoint, localCheckpoint.observedAt, local = true)
    private val remote = CheckpointCandidate(remoteCheckpoint, remoteCheckpoint.observedAt)
    private val launcher = CheckpointCandidate(launcherCheckpoint, launcherCheckpoint.observedAt)

    @Test
    fun keepLocalChoiceIgnoresNewerRemoteCheckpoint() {
        assertEquals(
            localCheckpoint,
            selectOpenCheckpoint(OpenProgressAuthority.LOCAL, local, remote, launcher),
        )
    }

    @Test
    fun keepLocalChoiceFallsBackToLauncherIntentWithoutLease() {
        assertEquals(
            launcherCheckpoint,
            selectOpenCheckpoint(OpenProgressAuthority.LOCAL, null, remote, launcher),
        )
    }

    @Test
    fun useRemoteChoiceWinsOverNewerLocalCheckpoint() {
        val staleRemote = CheckpointCandidate(remoteCheckpoint.copy(observedAt = 10_000), 10_000)
        assertEquals(
            staleRemote.checkpoint,
            selectOpenCheckpoint(OpenProgressAuthority.REMOTE, local, staleRemote, launcher),
        )
    }

    @Test
    fun useRemoteChoiceFallsBackToLocalSelectionWhenRemoteIsMissing() {
        assertEquals(
            localCheckpoint,
            selectOpenCheckpoint(OpenProgressAuthority.REMOTE, local, null, launcher),
        )
    }

    @Test
    fun automaticKeepsNewerRemoteCfiAtIdenticalPercentage() {
        val samePercentage = CheckpointCandidate(
            remoteCheckpoint.copy(totalProgression = localCheckpoint.totalProgression),
            remoteCheckpoint.observedAt,
        )
        assertEquals(
            samePercentage.checkpoint,
            selectOpenCheckpoint(OpenProgressAuthority.AUTOMATIC, local, samePercentage, launcher),
        )
    }

    @Test
    fun automaticKeepsNewerLocalCheckpointOverOlderRemote() {
        val olderRemote = CheckpointCandidate(remoteCheckpoint.copy(observedAt = 10_000), 10_000)
        assertEquals(
            localCheckpoint,
            selectOpenCheckpoint(OpenProgressAuthority.AUTOMATIC, local, olderRemote, launcher),
        )
    }

    @Test
    fun noCandidatesHasNoCheckpoint() {
        assertNull(selectOpenCheckpoint(OpenProgressAuthority.AUTOMATIC, null, null, null))
        assertNull(selectOpenCheckpoint(OpenProgressAuthority.REMOTE, null, null, null))
    }
}
