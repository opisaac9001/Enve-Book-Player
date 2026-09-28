package com.enve.app.storyalign

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class StoryAlignOutputStoreTest {

    @get:Rule val folder = TemporaryFolder()

    private val jobId = "job-1"

    @Test fun firstRunInstallsWithoutAPreviousVersion() {
        val store = store()
        store.prepareCandidate(jobId).writeText("first")

        assertEquals("first", store.promoteCandidate(jobId).readText())
        assertFalse(store.previousFile(jobId).exists())
    }

    @Test fun promotingKeepsTheReplacedOutput() {
        val store = store()
        store.prepareCandidate(jobId).writeText("first")
        store.promoteCandidate(jobId)

        store.prepareCandidate(jobId).writeText("second")
        store.promoteCandidate(jobId)

        assertEquals("second", store.acceptedFile(jobId).readText())
        assertEquals("first", store.previousFile(jobId).readText())
        assertFalse(store.candidateFile(jobId).exists())
    }

    @Test fun discardingACandidateLeavesTheAcceptedOutputAlone() {
        val store = store()
        store.prepareCandidate(jobId).writeText("first")
        store.promoteCandidate(jobId)

        store.prepareCandidate(jobId).writeText("half written")
        store.discardCandidate(jobId)

        assertEquals("first", store.acceptedFile(jobId).readText())
        assertFalse(store.candidateFile(jobId).exists())
    }

    @Test fun restoringSwapsBackAndStaysReversible() {
        val store = store()
        store.prepareCandidate(jobId).writeText("first")
        store.promoteCandidate(jobId)
        store.prepareCandidate(jobId).writeText("second")
        store.promoteCandidate(jobId)

        assertEquals("first", store.restorePrevious(jobId)?.readText())
        assertEquals("second", store.previousFile(jobId).readText())

        assertEquals("second", store.restorePrevious(jobId)?.readText())
        assertEquals("first", store.previousFile(jobId).readText())
    }

    @Test fun restoringWithoutAPreviousOutputDoesNothing() {
        val store = store()
        store.prepareCandidate(jobId).writeText("only")
        store.promoteCandidate(jobId)

        assertNull(store.restorePrevious(jobId))
        assertEquals("only", store.acceptedFile(jobId).readText())
    }

    @Test fun deletingRemovesEveryVersion() {
        val store = store()
        store.prepareCandidate(jobId).writeText("first")
        store.promoteCandidate(jobId)
        store.prepareCandidate(jobId).writeText("second")
        store.promoteCandidate(jobId)

        store.deleteAll(jobId)

        assertFalse(store.acceptedFile(jobId).exists())
        assertFalse(store.previousFile(jobId).exists())
    }

    @Test fun missingCandidateCannotDisplaceAcceptedOutput() {
        val store = store()
        store.prepareCandidate(jobId).writeText("first")
        store.promoteCandidate(jobId)
        assertTrue(runCatching { store.promoteCandidate(jobId) }.isFailure)
        assertEquals("first", store.acceptedFile(jobId).readText())
    }

    @Test fun jobsDoNotShareOutputs() {
        val store = store()
        store.prepareCandidate(jobId).writeText("first")
        store.promoteCandidate(jobId)
        store.prepareCandidate("job-2").writeText("other")
        store.promoteCandidate("job-2")

        store.deleteAll("job-2")

        assertTrue(store.acceptedFile(jobId).exists())
    }

    private fun store() = StoryAlignOutputStore(folder.newFolder("output"))
}
