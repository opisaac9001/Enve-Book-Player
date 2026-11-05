package com.enve.app.data.local

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.SdkSuppress
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.core.data.local.AudiobookGroupingOverrideStore
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.ConnectionScope
import com.enve.local.LocalLibraryRepository
import com.enve.local.LocalProviderAdapter
import dagger.hilt.android.EntryPointAccessors
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Collections
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
@SdkSuppress(minSdkVersion = 29)
class LocalAudioTrackLookupTest {
    private val sourceId = "local-lookup-fixture"
    private lateinit var directory: File
    private lateinit var provider: FixtureDocumentsProvider
    private lateinit var adapter: LocalProviderAdapter
    private lateinit var overrides: AudiobookGroupingOverrideStore
    private lateinit var dataScope: CoroutineScope

    @Before
    fun setUp(): Unit = runBlocking {
        val app = ApplicationProvider.getApplicationContext<Context>()
        val profiles = EntryPointAccessors.fromApplication(
            app,
            ProfileActivityBinding.DeviceEntryPoint::class.java,
        ).profiles()
        profiles.initialize()
        val preferences: PreferencesManager = checkNotNull(profiles.activeRuntime.value).component.preferences()
        directory = File(app.cacheDir, "local-lookup-${UUID.randomUUID()}").apply { mkdirs() }
        val audio = File(directory, "fixture.wav").apply { writeBytes(wave()) }
        provider = FixtureDocumentsProvider(audio)
        provider.attachInfo(app, ProviderInfo().apply { authority = provider.authority })
        val resolver = ContentResolver.wrap(provider)
        val context = object : ContextWrapper(app) {
            override fun getContentResolver(): ContentResolver = resolver
        }
        dataScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val dataStore = PreferenceDataStoreFactory.create(scope = dataScope) {
            File(directory, "lookup.preferences_pb")
        }
        val registry = ConnectionRegistry(dataStore)
        registry.upsert(ProviderConnection(sourceId, BookSource.LOCAL, "Fixture", provider.tree.toString(), ""))
        overrides = AudiobookGroupingOverrideStore(dataStore)
        val locations = ProfileStorageLocations.forProfile(DEFAULT_ADULT_PROFILE_ID, directory, directory, directory)
        adapter = LocalProviderAdapter(LocalLibraryRepository(context, overrides, locations), preferences, registry)
    }

    @After
    fun tearDown() {
        if (::provider.isInitialized) provider.releaseOpen.countDown()
        if (::dataScope.isInitialized) dataScope.cancel()
        if (::directory.isInitialized) directory.deleteRecursively()
    }

    @Test
    fun singleFileLookupDoesNotOpenUnrelatedBooks(): Unit = runBlocking {
        provider.add("root/selected", "Selected", directory = true)
        provider.add("root/selected/book", "Selected.m4b")
        provider.add("root/unrelated", "Unrelated", directory = true)
        provider.add("root/unrelated/audio", "Other.m4b")
        provider.add("root/unrelated/ebook", "Other.epub")

        val tracks = lookup("root/selected/book")

        assertEquals(listOf(provider.uri("root/selected/book").toString()), tracks.map { it.contentUrl })
        assertTrue("Unrelated books were opened: ${provider.opened}", provider.opened.none { it.startsWith("root/unrelated/") })
    }

    @Test
    fun multipartLookupKeepsNaturalOrderWithoutOpeningAnotherBook(): Unit = runBlocking {
        addMultipart()
        provider.add("root/other", "Other.m4b")

        val tracks = lookup("root/story/one")

        assertEquals(listOf("Story Chapter 1.mp3", "Story Chapter 2.mp3", "Story Chapter 10.mp3"), tracks.map { it.fileName })
        assertEquals(listOf(0, 1, 2), tracks.map { it.index })
        assertEquals(listOf(0L, 1_000L, 2_000L), tracks.map { it.cumulativeStartMs })
        assertEquals(listOf(1_000L, 1_000L, 1_000L), tracks.map { it.durationMs })
        assertTrue("Another book was opened: ${provider.opened}", "root/other" !in provider.opened)
    }

    @Test
    fun forcedStandaloneChapterDoesNotRejoinItsSiblingTracks(): Unit = runBlocking {
        addMultipart()
        overrides.forceStandalone(BookSource.LOCAL, sourceId, provider.uri("root/story/two").toString())

        val tracks = lookup("root/story/two")

        assertEquals(listOf(provider.uri("root/story/two").toString()), tracks.map { it.contentUrl })
        assertTrue("Sibling tracks were opened: ${provider.opened}", provider.opened.all { it == "root/story/two" })
    }

    @Test
    fun cancellationStopsBeforeOpeningTheNextTrack(): Unit = runBlocking {
        addMultipart()
        provider.blockedId = "root/story/one"
        val lookupScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        val job = lookupScope.launch { lookup("root/story/one") }
        try {
            assertTrue("Lookup did not reach the selected file", provider.openEntered.await(10, TimeUnit.SECONDS))
            job.cancel()
            provider.releaseOpen.countDown()
            withTimeout(10_000) { job.join() }
            assertEquals("Canceled lookup continued opening audio", listOf("root/story/one"), provider.opened.toList())
        } finally {
            provider.releaseOpen.countDown()
            lookupScope.cancel()
        }
    }

    private suspend fun lookup(id: String) = withContext(ConnectionScope.asContextElement(sourceId)) {
        adapter.getAudioTracks(
            Book(
                id = provider.uri(id).toString(),
                title = "Selected",
                source = BookSource.LOCAL,
                connectionId = sourceId,
                mediaType = AppMediaType.AUDIOBOOK,
                duration = 1L,
            ),
        ).getOrThrow()
    }

    private fun addMultipart() {
        provider.add("root/story", "Story", directory = true)
        provider.add("root/story/ten", "Story Chapter 10.mp3")
        provider.add("root/story/two", "Story Chapter 2.mp3")
        provider.add("root/story/one", "Story Chapter 1.mp3")
    }

    private fun wave(): ByteArray = ByteBuffer.allocate(32_044).order(ByteOrder.LITTLE_ENDIAN).apply {
        put("RIFF".toByteArray())
        putInt(32_036)
        put("WAVEfmt ".toByteArray())
        putInt(16)
        putShort(1)
        putShort(1)
        putInt(16_000)
        putInt(32_000)
        putShort(2)
        putShort(16)
        put("data".toByteArray())
        putInt(32_000)
    }.array()

    private class FixtureDocumentsProvider(private val audio: File) : ContentProvider() {
        val authority = "com.enve.fixture.local.lookup"
        val tree: Uri = DocumentsContract.buildTreeDocumentUri(authority, "root")
        val opened: MutableList<String> = Collections.synchronizedList(mutableListOf())
        val openEntered = CountDownLatch(1)
        val releaseOpen = CountDownLatch(1)
        var blockedId: String? = null
        private val documents = linkedMapOf("root" to Document("root", "Library", true))

        fun add(id: String, name: String, directory: Boolean = false) {
            documents[id] = Document(id, name, directory)
        }

        fun uri(id: String): Uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)

        override fun onCreate(): Boolean = true

        override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
            val id = DocumentsContract.getDocumentId(uri)
            val matches = if (uri.lastPathSegment == "children") {
                documents.values.filter { it.id.substringBeforeLast('/', "") == id }
            } else {
                listOfNotNull(documents[id])
            }
            val columns = projection ?: arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                DocumentsContract.Document.COLUMN_FLAGS,
            )
            return MatrixCursor(columns).apply {
                matches.forEach { document ->
                    addRow(columns.map { column ->
                        when (column) {
                            DocumentsContract.Document.COLUMN_DOCUMENT_ID -> document.id
                            DocumentsContract.Document.COLUMN_DISPLAY_NAME -> document.name
                            DocumentsContract.Document.COLUMN_MIME_TYPE -> if (document.directory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream"
                            DocumentsContract.Document.COLUMN_SIZE -> audio.length()
                            DocumentsContract.Document.COLUMN_LAST_MODIFIED -> 1L
                            DocumentsContract.Document.COLUMN_FLAGS -> 0
                            else -> null
                        }
                    })
                }
            }
        }

        override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
            val id = DocumentsContract.getDocumentId(uri)
            opened += id
            if (id == blockedId) {
                openEntered.countDown()
                check(releaseOpen.await(10, TimeUnit.SECONDS))
            }
            return ParcelFileDescriptor.open(audio, ParcelFileDescriptor.MODE_READ_ONLY)
        }

        override fun getType(uri: Uri): String = "application/octet-stream"
        override fun insert(uri: Uri, values: ContentValues?): Uri? = error("Read-only fixture")
        override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = error("Read-only fixture")
        override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = error("Read-only fixture")

        private data class Document(val id: String, val name: String, val directory: Boolean)
    }
}
