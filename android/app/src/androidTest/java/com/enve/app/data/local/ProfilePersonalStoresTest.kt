package com.enve.app.data.local

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.data.duplicates.DuplicateGroupStore
import com.enve.app.data.podcasts.PodcastSubscriptionStore
import com.enve.app.playback.PlayerBookmarkService
import com.enve.audiobookshelf.listening.AbsLocalListeningSession
import com.enve.audiobookshelf.listening.AbsLocalListeningStore
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.HearthDismissedShelfStore
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.Book
import com.enve.engine.podcasts.PodcastSubscription
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProfilePersonalStoresTest {
    private val application = ApplicationProvider.getApplicationContext<Context>()
    private val preferenceNames = mutableSetOf<String>()
    private val prefix = "profile-personal-test-${UUID.randomUUID()}"
    private val context = object : ContextWrapper(application) {
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            val isolatedName = "$prefix-$name"
            preferenceNames += isolatedName
            return application.getSharedPreferences(isolatedName, mode)
        }
    }
    private lateinit var root: File
    private val book = Book(id = "same-book", title = "Book", connectionId = "same-connection")

    @Before
    fun setUp() {
        root = File(application.cacheDir, prefix)
        check(File(root, "files").mkdirs())
    }

    @After
    fun tearDown() {
        preferenceNames.forEach(application::deleteSharedPreferences)
        root.deleteRecursively()
    }

    @Test
    fun bookmarksRemainIndependentAcrossReopenAndLateOutgoingWrite() = runBlocking {
        val owner = PlayerBookmarkService(locations(DEFAULT_ADULT_PROFILE_ID))
        val child = PlayerBookmarkService(locations("child-one"))
        val ownerBookmark = owner.addBookmark(book, 10, "Owner", null, null)
        assertTrue(child.loadBookmarks(book).isEmpty())
        val childBookmark = child.addBookmark(book, 20, "Child", null, null)
        val release = CompletableDeferred<Unit>()
        val outgoing = launch {
            release.await()
            owner.addBookmark(book, 30, "Late owner", null, null)
        }
        release.complete(Unit)
        outgoing.join()
        assertEquals(listOf(childBookmark), child.loadBookmarks(book))
        assertEquals(listOf(childBookmark), PlayerBookmarkService(locations("child-one")).loadBookmarks(book))
        assertEquals(2, PlayerBookmarkService(locations(DEFAULT_ADULT_PROFILE_ID)).loadBookmarks(book).size)
        child.deleteBookmark(book, childBookmark)
        assertTrue(PlayerBookmarkService(locations("child-one")).loadBookmarks(book).isEmpty())
        assertTrue(owner.loadBookmarks(book).contains(ownerBookmark))
        assertTrue(File(root, "files/audiobook-bookmarks/same-book.json").isFile)
    }

    @Test
    fun dismissedShelvesKeepOwnerNamespaceAndReopenChildIndependently() {
        val owner = HearthDismissedShelfStore(context)
        owner.dismiss("same-key")
        assertEquals(setOf("same-key"), HearthDismissedShelfStore(context, locations(DEFAULT_ADULT_PROFILE_ID)).keys.value)
        val child = HearthDismissedShelfStore(context, locations("child-one"))
        assertTrue(child.keys.value.isEmpty())
        child.dismiss("child-key")
        owner.dismiss("late-owner")
        assertEquals(setOf("child-key"), HearthDismissedShelfStore(context, locations("child-one")).keys.value)
        assertEquals(setOf("same-key", "late-owner"), HearthDismissedShelfStore(context).keys.value)
    }

    @Test
    fun duplicateGroupsKeepIdenticalBookKeysIndependent() {
        val owner = DuplicateGroupStore(context)
        owner.group(listOf("same-key", "owner-keeper"), "owner-keeper")
        assertEquals(owner.groups.value, DuplicateGroupStore(context, locations(DEFAULT_ADULT_PROFILE_ID)).groups.value)
        val child = DuplicateGroupStore(context, locations("child-one"))
        assertTrue(child.groups.value.isEmpty())
        child.group(listOf("same-key", "child-keeper"), "child-keeper")
        owner.ungroup("owner-keeper")
        assertEquals(mapOf("same-key" to "child-keeper"), DuplicateGroupStore(context, locations("child-one")).groups.value)
        assertTrue(DuplicateGroupStore(context).groups.value.isEmpty())
    }

    @Test
    fun podcastSubscriptionsKeepIdenticalFeedsIndependent() {
        val owner = PodcastSubscriptionStore(context)
        val source = PodcastSubscription("https://example.test/feed", "Owner", null, null, 1)
        owner.save(source)
        assertEquals(listOf(source), PodcastSubscriptionStore(context, locations(DEFAULT_ADULT_PROFILE_ID)).subscriptions.value)
        val child = PodcastSubscriptionStore(context, locations("child-one"))
        assertTrue(child.subscriptions.value.isEmpty())
        val destination = source.copy(title = "Child", subscribedAtMs = 2)
        child.save(destination)
        owner.remove(source.feedUrl)
        assertEquals(listOf(destination), PodcastSubscriptionStore(context, locations("child-one")).subscriptions.value)
        assertTrue(PodcastSubscriptionStore(context).subscriptions.value.isEmpty())
    }

    @Test
    fun listeningSessionsDeviceIdsAndUploadReceiptsRemainIndependent() = runBlocking {
        val owner = AbsLocalListeningStore(context)
        val source = session(80.0)
        owner.enqueueHistory(source)
        val ownerReopened = AbsLocalListeningStore(context, locations(DEFAULT_ADULT_PROFILE_ID))
        assertEquals(listOf(source), ownerReopened.pending("same-connection", "same-account"))
        val child = AbsLocalListeningStore(context, locations("child-one"))
        assertTrue(child.pending("same-connection", "same-account").isEmpty())
        val destination = session(20.0)
        child.enqueueHistory(destination)
        assertNotEquals(owner.deviceInfo.deviceId, child.deviceInfo.deviceId)
        owner.markUploaded(listOf(source), emptySet())
        val reopened = AbsLocalListeningStore(context, locations("child-one"))
        assertEquals(listOf(destination), reopened.pending("same-connection", "same-account"))
        assertEquals(child.deviceInfo.deviceId, reopened.deviceInfo.deviceId)
        child.removeCrossProviderHistory("same-book-key")
        assertTrue(AbsLocalListeningStore(context, locations("child-one")).pending("same-connection", "same-account").isEmpty())
        assertTrue(AbsLocalListeningStore(context).pending("same-connection", "same-account").isEmpty())
        assertEquals(owner.deviceInfo.deviceId, AbsLocalListeningStore(context).deviceInfo.deviceId)
    }

    @Test
    fun blockedChildFileRootsCannotFallbackToOwner() = runBlocking {
        val ownerLocations = locations(DEFAULT_ADULT_PROFILE_ID)
        val ownerBookmarks = PlayerBookmarkService(ownerLocations)
        ownerBookmarks.addBookmark(book, 10, "Owner", null, null)
        val bookmarkFile = File(ownerLocations.filesDirectory, "audiobook-bookmarks/same-book.json")
        val bookmarkBytes = bookmarkFile.readBytes()
        val childLocations = locations("child-blocked")
        check(childLocations.filesDirectory.parentFile!!.mkdirs())
        childLocations.filesDirectory.writeText("blocked")
        try {
            PlayerBookmarkService(childLocations)
            fail("Blocked bookmark root must fail")
        } catch (_: IllegalStateException) {
        }
        assertTrue(bookmarkBytes.contentEquals(bookmarkFile.readBytes()))
        assertEquals("blocked", childLocations.filesDirectory.readText())
        assertEquals(1, ownerBookmarks.loadBookmarks(book).size)
    }

    @Test
    fun corruptChildBookmarksRejectReadsAndUpdatesWithoutOverwriting() = runBlocking {
        val ownerLocations = locations(DEFAULT_ADULT_PROFILE_ID)
        val owner = PlayerBookmarkService(ownerLocations)
        val bookmark = owner.addBookmark(book, 80, "Owner", null, null)
        val ownerFile = File(ownerLocations.filesDirectory, "audiobook-bookmarks/same-book.json")
        val ownerBytes = ownerFile.readBytes()
        val childLocations = locations("child-corrupt")
        val child = PlayerBookmarkService(childLocations)
        val childFile = File(childLocations.filesDirectory, "audiobook-bookmarks/same-book.json")
        childFile.writeText("corrupt bookmarks")
        try {
            child.loadBookmarks(book)
            fail("Corrupt child bookmarks must fail reading")
        } catch (_: kotlinx.serialization.SerializationException) {
        }
        try {
            child.addBookmark(book, 20, "Child", null, null)
            fail("Corrupt child bookmarks must fail updating")
        } catch (_: kotlinx.serialization.SerializationException) {
        }
        try {
            child.deleteBookmark(book, bookmark)
            fail("Corrupt child bookmarks must fail deleting")
        } catch (_: kotlinx.serialization.SerializationException) {
        }
        assertEquals("corrupt bookmarks", childFile.readText())
        assertTrue(ownerBytes.contentEquals(ownerFile.readBytes()))
        assertEquals(listOf(bookmark), PlayerBookmarkService(ownerLocations).loadBookmarks(book))
        childFile.writeText("")
        try {
            child.addBookmark(book, 20, "Child", null, null)
            fail("Empty existing child bookmarks must fail updating")
        } catch (_: kotlinx.serialization.SerializationException) {
        }
        assertEquals(0L, childFile.length())
    }

    private fun locations(profileId: String) = ProfileStorageLocations.forProfile(
        profileId = profileId,
        filesDirectory = File(root, "files"),
        cacheDirectory = File(root, "cache"),
        databaseDirectory = File(root, "databases"),
    )

    private fun session(position: Double) = AbsLocalListeningSession(
        id = "same-session",
        connectionId = "same-connection",
        libraryItemId = "same-book",
        displayTitle = "Book",
        day = "2026-10-06",
        dayOfWeek = "Tuesday",
        durationSec = 100.0,
        timeListeningSec = 10.0,
        currentTimeSec = position,
        startedAtMs = 1_000,
        updatedAtMs = 11_000,
        accountId = "same-account",
        sourceBookKey = "same-book-key",
    )
}
