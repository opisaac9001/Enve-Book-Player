package com.enve.app.data.local

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.history.HistorySessionStore
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import com.enve.core.data.model.HistorySessionOrigin
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProfileHistorySessionStoreTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private lateinit var root: File

    @Before
    fun setUp() {
        root = File(context.cacheDir, "profile-history-test-${UUID.randomUUID()}")
        check(root.mkdirs())
    }

    @After
    fun tearDown() {
        root.deleteRecursively()
    }

    @Test
    fun ownerPathIsLegacyAndNewProfileDoesNotInheritHistory() = runBlocking {
        val ownerLocations = locations(DEFAULT_ADULT_PROFILE_ID)
        assertEquals(File(root, "files/history/history_sessions.json"), ownerLocations.historySessionsFile)
        val owner = HistorySessionStore(ownerLocations)
        assertTrue(owner.append(session(duration = 60)))

        val childLocations = locations("child-one")
        assertEquals(
            File(root, "files/profiles/child-one/history/history_sessions.json"),
            childLocations.historySessionsFile,
        )
        assertTrue(HistorySessionStore(childLocations).sessions.value.isEmpty())
    }

    @Test
    fun identicalSessionBookAndConnectionIdsRemainIndependentAfterReopen() = runBlocking {
        val ownerLocations = locations(DEFAULT_ADULT_PROFILE_ID)
        val childLocations = locations("child-one")
        val owner = HistorySessionStore(ownerLocations)
        val child = HistorySessionStore(childLocations)
        val ownerSession = session(duration = 120)
        val childSession = session(duration = 30)

        assertTrue(owner.append(ownerSession))
        assertTrue(child.append(childSession))
        assertEquals(listOf(ownerSession), owner.sessions.value)
        assertEquals(listOf(childSession), child.sessions.value)
        assertEquals(listOf(ownerSession), HistorySessionStore(ownerLocations).sessions.value)
        assertEquals(listOf(childSession), HistorySessionStore(childLocations).sessions.value)
    }

    @Test
    fun lateOutgoingAppendAndRemoteReplacementCannotPublishIntoDestination() = runBlocking {
        val ownerLocations = locations(DEFAULT_ADULT_PROFILE_ID)
        val childLocations = locations("child-one")
        val owner = HistorySessionStore(ownerLocations)
        val child = HistorySessionStore(childLocations)
        val childSession = session(duration = 30)
        val releaseOutgoing = CompletableDeferred<Unit>()
        val outgoing = launch {
            releaseOutgoing.await()
            assertTrue(owner.append(session(duration = 120)))
        }
        assertTrue(child.append(childSession))
        releaseOutgoing.complete(Unit)
        outgoing.join()

        assertEquals(listOf(childSession), child.sessions.value)
        assertEquals(listOf(childSession), HistorySessionStore(childLocations).sessions.value)
        val remote = session(duration = 50).copy(
            id = "remote-session",
            startTimeMs = 20_000L,
            endTimeMs = 70_000L,
            origin = HistorySessionOrigin.BOOKORBIT,
        )
        assertEquals(1, owner.replaceBookOrbitSessions("same-connection", "same-book", listOf(remote)))
        assertEquals(listOf(childSession), child.sessions.value)
        assertEquals(listOf(childSession), HistorySessionStore(childLocations).sessions.value)
    }

    @Test
    fun malformedDestinationCannotMutateOwnerOrFallbackToItsHistory() = runBlocking {
        val ownerLocations = locations(DEFAULT_ADULT_PROFILE_ID)
        val owner = HistorySessionStore(ownerLocations)
        val ownerSession = session(duration = 120)
        assertTrue(owner.append(ownerSession))
        val ownerBytes = ownerLocations.historySessionsFile.readBytes()

        val childLocations = locations("child-one")
        check(childLocations.historySessionsFile.parentFile!!.mkdirs())
        childLocations.historySessionsFile.writeText("malformed history")
        try {
            HistorySessionStore(childLocations)
            fail("Malformed child history must fail activation")
        } catch (_: kotlinx.serialization.SerializationException) {
        }
        assertEquals("malformed history", childLocations.historySessionsFile.readText())
        assertTrue(ownerBytes.contentEquals(ownerLocations.historySessionsFile.readBytes()))
        assertEquals(listOf(ownerSession), owner.sessions.value)
        assertEquals(listOf(ownerSession), HistorySessionStore(ownerLocations).sessions.value)
        assertTrue(ownerBytes.contentEquals(ownerLocations.historySessionsFile.readBytes()))
    }

    @Test
    fun childDirectoryCreationFailureLeavesOwnerUsable() = runBlocking {
        val ownerLocations = locations(DEFAULT_ADULT_PROFILE_ID)
        val owner = HistorySessionStore(ownerLocations)
        val ownerSession = session(duration = 120)
        assertTrue(owner.append(ownerSession))
        val ownerBytes = ownerLocations.historySessionsFile.readBytes()
        val childLocations = locations("child-blocked")
        check(childLocations.filesDirectory.mkdirs())
        val blockedParent = childLocations.historySessionsFile.parentFile!!
        blockedParent.writeText("file blocking history directory")

        try {
            HistorySessionStore(childLocations)
            fail("Child history directory creation must fail")
        } catch (_: IllegalStateException) {
        }

        assertEquals("file blocking history directory", blockedParent.readText())
        assertTrue(ownerBytes.contentEquals(ownerLocations.historySessionsFile.readBytes()))
        assertEquals(listOf(ownerSession), owner.sessions.value)
        val updatedOwnerSession = session(duration = 180)
        assertTrue(owner.append(updatedOwnerSession))
        assertEquals(listOf(updatedOwnerSession), HistorySessionStore(ownerLocations).sessions.value)
    }

    @Test
    fun ownerRetainsLegacyMalformedHistoryBehavior() {
        val ownerLocations = locations(DEFAULT_ADULT_PROFILE_ID)
        check(ownerLocations.historySessionsFile.parentFile!!.mkdirs())
        ownerLocations.historySessionsFile.writeText("malformed owner history")

        assertTrue(HistorySessionStore(ownerLocations).sessions.value.isEmpty())
        assertEquals("malformed owner history", ownerLocations.historySessionsFile.readText())
    }

    private fun locations(profileId: String) = ProfileStorageLocations.forProfile(
        profileId = profileId,
        filesDirectory = File(root, "files"),
        cacheDirectory = File(root, "cache"),
        databaseDirectory = File(root, "databases"),
    )

    private fun session(duration: Long) = HistorySession(
        id = "same-session",
        bookId = "42",
        bookKey = "same-book",
        connectionId = "same-connection",
        source = BookSource.GRIMMORY,
        mediaType = AppMediaType.AUDIOBOOK,
        startTimeMs = 1_000L,
        endTimeMs = 1_000L + duration * 1_000L,
        activeDurationSeconds = duration,
    )
}
