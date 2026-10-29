package com.enve.app.listeningposition

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.profiles.DaggerProfileRuntimeComponent
import com.enve.app.profiles.ProfileResources
import com.enve.app.profiles.ProfileViewModelFactory
import com.enve.app.viewmodel.ReaderViewModel
import com.enve.app.viewmodel.OpenProgressAuthority
import com.enve.app.viewmodel.OpenRemoteProgress
import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.ReaderCheckpointIdentity
import com.enve.core.reader.ReaderEngineKind
import com.enve.core.data.provider.ProviderEbookResource
import androidx.lifecycle.ViewModelStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import com.enve.core.listeningposition.SharedReadingLocation
import com.enve.core.data.model.BookSource
import com.enve.core.listeningposition.ListeningPositionPayload
import com.enve.engine.listeningposition.ListeningPositionServerStatus
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ListeningPositionIntegrationTest {
    @Test fun confirmedRewindChangesOnlyTheSelectedCopyInAnIsolatedProfile() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val resources = ProfileResources.open(context, UUID.randomUUID().toString())
        try {
            val component = DaggerProfileRuntimeComponent.factory().create(resources)
            val book = Book("position-fixture", "Shared Position Fixture", author = "Enve Test", duration = 3600,
                currentTime = 900, isFinished = true, serverReadStatus = "READ", source = BookSource.LOCAL, connectionId = "one")
            val other = book.copy(connectionId = "two")
            component.bookCacheDao().upsert(listOf(book.toCachedBook(), other.toCachedBook()))
            val payload = ListeningPositionPayload(90000, 3600000, book.title, listOf("Enve Test"))
            val facade = component.listeningPosition()
            assertEquals(2, facade.suggestions(payload).size)
            val result = facade.apply(payload, book)
            assertEquals(ListeningPositionServerStatus.SYNC_DISABLED, result.server)
            assertEquals(90L, result.book.currentTime)
            assertFalse(result.book.isFinished)
            assertEquals("RE_READING", result.book.serverReadStatus)
            assertEquals(900L, component.bookCacheDao().getByCacheKey(other.uniqueKey)!!.currentTime)
            assertNull(component.bookCacheDao().getPendingAudiobookProgress(book.id, book.source.name, "one"))
            component.serverSync().setEnabled(true)
            val unknown = book.copy(id = "unknown-length", source = BookSource.AUDIOBOOKSHELF, duration = 0)
            component.bookCacheDao().upsert(listOf(unknown.toCachedBook()))
            val localOnly = facade.apply(payload, unknown)
            assertEquals(ListeningPositionServerStatus.UNKNOWN_LENGTH, localOnly.server)
            assertEquals(90L, localOnly.book.currentTime)
            assertNull(component.bookCacheDao().getPendingAudiobookProgress(unknown.id, unknown.source.name, "one"))
        } finally {
            resources.close()
            resources.locations.filesDirectory.deleteRecursively()
            resources.locations.cacheDirectory.deleteRecursively()
            resources.locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }
    @Test fun readingRewindsSaveEachNativeFormatWithoutChangingOtherCopies() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val resources = ProfileResources.open(context, UUID.randomUUID().toString())
        try {
            val component = DaggerProfileRuntimeComponent.factory().create(resources)
            val books = listOf("EPUB", "MOBI", "AZW3", "PDF", "CBZ").map { format ->
                Book("reading-$format", "Shared Reading Fixture", author = "Enve Test", mediaType = AppMediaType.EBOOK,
                    primaryFileType = format, pageCount = 20, epubProgress = 0.9f, readProgress = 0.9f,
                    epubLocator = "{\"page\":18}", isFinished = true, serverReadStatus = "READ", source = BookSource.LOCAL, connectionId = "one")
            }
            val other = books.first().copy(connectionId = "two")
            component.bookCacheDao().upsert((books + other).map { it.toCachedBook() })
            val facade = component.listeningPosition()
            for (book in books) {
                val fixed = book.primaryFileType in setOf("PDF", "CBZ")
                val format = SharedReadingLocation.format(book)
                val location = SharedReadingLocation(format, 250000,
                    if (!fixed) "OPS/chapter.xhtml" else null, if (!fixed) 500000 else null,
                    if (fixed) 5 else null, if (fixed) 20 else null)
                val payload = ListeningPositionPayload(0, 0, book.title, listOf("Enve Test"), readingLocation = location)
                val result = facade.apply(payload, book)
                assertEquals(0.25f, result.book.epubProgress!!, 0.00001f)
                assertFalse(result.book.isFinished)
                assertEquals("RE_READING", result.book.serverReadStatus)
                assertEquals(ListeningPositionServerStatus.SYNC_DISABLED, result.server)
                if (fixed) assertEquals("{\"page\":5,\"enveSharedPosition\":true}", result.book.epubLocator)
                else assertTrue(result.book.epubLocator!!.contains("OPS/chapter.xhtml"))
                val start = facade.apply(payload.copy(readingLocation = SharedReadingLocation(format, 0)), result.book)
                assertEquals(0f, start.book.epubProgress!!, 0.00001f)
                if (fixed) assertEquals("{\"page\":1,\"enveSharedPosition\":true}", start.book.epubLocator)
                else {
                    assertTrue(SharedReadingLocation.isSharedPosition(start.book.epubLocator))
                    assertFalse(start.book.epubLocator!!.contains("OPS/chapter.xhtml"))
                }
                assertFalse(start.book.isFinished)
            }
            assertEquals(0.9f, component.bookCacheDao().getByCacheKey(other.uniqueKey)!!.epubProgress!!, 0.00001f)
        } finally {
            resources.close()
            resources.locations.filesDirectory.deleteRecursively()
            resources.locations.cacheDirectory.deleteRecursively()
            resources.locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }

    @Test fun confirmedReadingZeroBeatsAnExistingBridgeCheckpointWithoutClearingAnotherCopy() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val resources = ProfileResources.open(context, UUID.randomUUID().toString())
        val models = ViewModelStore()
        var factory: ProfileViewModelFactory? = null
        try {
            val component = DaggerProfileRuntimeComponent.factory().create(resources)
            val book = Book("bridge-location", "Bridge Location", mediaType = AppMediaType.EBOOK, primaryFileType = "EPUB",
                epubProgress = 0.8f, readProgress = 0.8f, source = BookSource.LOCAL, connectionId = "one", currentTime = 900)
            component.bookCacheDao().upsert(listOf(book.toCachedBook()))
            val store = component.epubBridgeCheckpointStore()
            val resource = ProviderEbookResource(url = "file:///fixture.epub", format = "EPUB", providerFileId = "file")
            val key = ReaderCheckpointIdentity.key(book.source, book.connectionId, book.id, resource.providerFileId, "fixture-publication")
            val otherKey = ReaderCheckpointIdentity.key(book.source, "two", book.id, resource.providerFileId, "fixture-publication")
            for (bookKey in listOf(key, otherKey)) {
                val lease = store.beginSession(bookKey, "fixture-publication", resource.providerFileId, ReaderEngineKind.FOLIATE)
                assertNotNull(store.commit(lease, EpubBridgeCheckpoint(publicationSha256 = "fixture-publication", providerFileId = "file",
                    writerEpoch = lease.writerEpoch, observedAt = 100, sourceEngine = ReaderEngineKind.FOLIATE,
                    href = "OPS/old.xhtml", epubCfi = "epubcfi(/6/2!/4/2:0)", totalProgression = 0.8)))
            }
            component.listeningPosition().apply(ListeningPositionPayload(0, 0, book.title,
                readingLocation = SharedReadingLocation("epub", 0)), book)
            val vm = withContext(Dispatchers.Main) {
                factory = ProfileViewModelFactory(component)
                factory!!.create(ReaderViewModel::class.java).also {
                    models.put("reader", it)
                    it.init(book.id, book.source, book.connectionId, book.title)
                }
            }
            val cached = vm.cachedReaderProgress()!!
            assertEquals(0f, cached.progress, 0f)
            assertTrue(SharedReadingLocation.isSharedPosition(cached.locator))
            assertTrue(cached.updatedAt > 100)
            val plan = vm.prepareEpubEngineOpen(ReaderEngineKind.FOLIATE, resource, "fixture-publication", cached.locator,
                cached.progress, cached.updatedAt, OpenRemoteProgress(null, OpenProgressAuthority.LOCAL))
            assertEquals(0.0, plan.initialCheckpoint!!.totalProgression!!, 0.0)
            assertNull(plan.initialCheckpoint!!.href)
            assertNull(plan.initialCheckpoint!!.epubCfi)
            assertEquals(0.8, store.checkpoint(otherKey)!!.totalProgression!!, 0.0)
        } finally {
            withContext(Dispatchers.Main) { models.clear(); factory?.retire() }
            resources.close()
            resources.locations.filesDirectory.deleteRecursively()
            resources.locations.cacheDirectory.deleteRecursively()
            resources.locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }

}
