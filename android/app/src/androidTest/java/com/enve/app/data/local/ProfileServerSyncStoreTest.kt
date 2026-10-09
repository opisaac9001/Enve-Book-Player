package com.enve.app.data.local

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileServerSyncStore
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import java.io.File
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProfileServerSyncStoreTest {
    private val base = ApplicationProvider.getApplicationContext<Context>()
    private val prefix = "profile-sync-test-${UUID.randomUUID()}-"
    private val names = mutableSetOf<String>()
    private val context = object : ContextWrapper(base) {
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            names += prefix + name
            return base.getSharedPreferences(prefix + name, mode)
        }
    }

    @After
    fun cleanUp() { names.forEach(base::deleteSharedPreferences) }

    private fun store(id: String) = ProfileServerSyncStore(context, ProfileStorageLocations.forProfile(
        id, File(base.cacheDir, prefix + "files"), File(base.cacheDir, prefix + "cache"), File(base.cacheDir, prefix + "databases"),
    ))

    @Test
    fun ownerDefaultAndChildOptInPersistIndependently() = runBlocking {
        val owner = store(DEFAULT_ADULT_PROFILE_ID)
        val child = store("test-child")
        assertTrue(owner.isEnabled)
        assertFalse(child.isEnabled)
        child.setEnabled(true)
        assertTrue(store("test-child").isEnabled)
        assertTrue(store(DEFAULT_ADULT_PROFILE_ID).isEnabled)
        child.setEnabled(false)
        assertFalse(store("test-child").isEnabled)
        assertTrue(owner.isEnabled)
    }

    @Test
    fun optingInDoesNotAdmitActivityFromBeforeOptIn() = runBlocking {
        val child = store("test-child")
        assertFalse(child.accepts(0L))
        child.setEnabled(true)
        assertFalse(child.accepts(child.enabledSince - 1L))
        assertTrue(child.accepts(child.enabledSince))
        val reopened = store("test-child")
        assertFalse(reopened.accepts(reopened.enabledSince - 1L))
        assertTrue(reopened.accepts(reopened.enabledSince))
    }

    @Test
    fun disablingRejectsAnAdmittedResolutionAcrossLaterOptIn() = runBlocking {
        val child = store("test-child")
        child.setEnabled(true)
        val admittedAt = child.enabledSince
        assertTrue(child.accepts(admittedAt))
        child.setEnabled(false)
        assertFalse(child.accepts(admittedAt))
        while (System.currentTimeMillis() <= admittedAt) kotlinx.coroutines.delay(1L)
        child.setEnabled(true)
        assertFalse(child.accepts(admittedAt))
        assertTrue(child.accepts(child.enabledSince))
    }

    @Test
    fun disabledCatalogKeepsMetadataAndDiscardsRemotePersonalState() {
        val book = Book(id = "shared", title = "Shared book", source = BookSource.GRIMMORY,
            currentTime = 80L, readProgress = 0.8f, epubProgress = 0.8f, epubLocator = "remote",
            lastReadTime = 100L, isFinished = true, serverReadStatus = "READ")
        val sanitized = store("test-child").catalogBook(book)
        assertEquals(book.id, sanitized.id)
        assertEquals(book.title, sanitized.title)
        assertEquals(0L, sanitized.currentTime)
        assertEquals(0f, sanitized.readProgress)
        assertEquals(null, sanitized.epubLocator)
        assertFalse(sanitized.isFinished)
        assertEquals(book, store(DEFAULT_ADULT_PROFILE_ID).catalogBook(book))
    }
}
