package com.enve.app.document

import android.content.Context
import android.graphics.Bitmap
import androidx.documentfile.provider.DocumentFile
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.app.ui.screens.EbookReaderActivity
import com.enve.app.viewmodel.ReaderViewModel
import com.enve.core.data.local.AudiobookGroupingOverrideStore
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.reader.ReaderEngineKind
import com.enve.local.LocalLibraryRepository
import dagger.hilt.android.EntryPointAccessors
import java.io.File
import java.io.FileInputStream
import java.net.ServerSocket
import java.util.Collections
import kotlin.concurrent.thread
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.UrlScheme
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import com.enve.app.ui.screens.reader.ReaderEngineNavigator
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.readium.r2.navigator.epub.EpubNavigatorFragment

@RunWith(AndroidJUnit4::class)
class Azw3SupportTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Test
    fun localScanIncludesAzw3InNestedFoldersAndPreservesFormat() {
        val root = File(context.cacheDir, "azw3-scan-${UUID.randomUUID()}").apply { mkdirs() }
        try {
            File(root, "First.azw3").writeText("Kindle fixture")
            File(root, "nested").apply { mkdirs() }.resolve("Second.AZW3").writeText("Kindle fixture")
            File(root, "ignored.txt").writeText("Not a book")
            val repository = LocalLibraryRepository(
                context,
                AudiobookGroupingOverrideStore(context),
                ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
            )
            val books = mutableListOf<Book>()
            LocalLibraryRepository::class.java.getDeclaredMethod(
                "scanRecursive", DocumentFile::class.java, List::class.java, Set::class.java,
            ).apply { isAccessible = true }.invoke(repository, DocumentFile.fromFile(root), books, emptySet<String>())
            assertEquals(setOf("First", "Second"), books.map { it.title }.toSet())
            assertTrue(books.all { it.mediaType == AppMediaType.EBOOK && it.source == BookSource.LOCAL })
            assertTrue(books.all { it.primaryFileType == "AZW3" })
        } finally {
            root.deleteRecursively()
        }
    }

    @Test
    fun azw3OpensDirectlyInFoliateAndRestoresPositionWithoutAnEpub() = verifyDirectAzw3(BookSource.LOCAL)

    @Test
    fun grimmoryDownloadsAzw3AndOpensItDirectlyInFoliate() = verifyDirectAzw3(BookSource.GRIMMORY)

    private fun verifyDirectAzw3(bookSource: BookSource) = runBlocking {
        val fixturePath = InstrumentationRegistry.getArguments().getString("kindleFixturePath")
        assumeTrue(fixturePath != null)
        val staged = File(requireNotNull(fixturePath)).canonicalFile
        require(staged.parent == "/data/local/tmp" && staged.name.matches(Regex("[a-zA-Z0-9._-]+\\.azw3")))
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use {
            withTimeout(15_000) {
                while (coordinator.activeRuntime.value == null) delay(100)
            }
        }
        val component = checkNotNull(coordinator.activeRuntime.value).component
        val locations = component.storageLocations()
        val id = System.currentTimeMillis().toString()
        val source = File(locations.cacheDirectory, "ebooks/$id.azw3")
        val normalized = File(locations.cacheDirectory, "normalized-ebooks/$id.epub")
        source.parentFile!!.mkdirs()
        InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand("cat ${staged.path}").use { descriptor ->
            FileInputStream(descriptor.fileDescriptor).use { input -> source.outputStream().use { input.copyTo(it) } }
        }
        val connectionId = if (bookSource == BookSource.GRIMMORY) "azw3-fixture-${UUID.randomUUID()}" else null
        val requests = Collections.synchronizedList(mutableListOf<String>())
        val socket = connectionId?.let { ServerSocket(0) }
        val fixtureBytes = source.readBytes()
        val worker = socket?.let { server ->
            source.delete()
            thread(isDaemon = true, name = "azw3-grimmory-fixture") {
                while (!server.isClosed) {
                    val client = runCatching { server.accept() }.getOrNull() ?: break
                    client.use {
                        val input = it.getInputStream().bufferedReader()
                        val request = input.readLine() ?: return@use
                        while (!input.readLine().isNullOrEmpty()) { }
                        val path = request.split(' ')[1]
                        requests += path
                        val content = path == "/api/v1/books/$id/content?bookType=AZW3"
                        val detail = path == "/api/v1/app/books/$id"
                        val body = when {
                            content -> fixtureBytes
                            detail -> """{"id":$id,"title":"AZW3 fixture","primaryFile":{"id":777,"bookType":"AZW3","fileName":"fixture.azw3"}}""".toByteArray()
                            else -> "[]".toByteArray()
                        }
                        val mediaType = if (content) "application/vnd.amazon.mobi8-ebook" else "application/json"
                        it.getOutputStream().apply {
                            write("HTTP/1.1 200 OK\r\nContent-Type: $mediaType\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
                            write(body)
                            flush()
                        }
                    }
                }
            }
        }
        val intent = EbookReaderActivity.createIntent(
            context, id, bookSource, connectionId = connectionId, title = "AZW3 verification", author = "libmobi fixture",
            bookFormat = "AZW3",
            epubLocator = """{"href":"OEBPS/chapter_0000.xhtml","locations":{"totalProgression":0.25,"progression":0.25}}""",
            epubProgress = 0.25f, readerEngine = ReaderEngineKind.READIUM,
        )
        try {
            if (connectionId != null && socket != null) {
                component.connections().upsert(ProviderConnection(
                    id = connectionId, source = BookSource.GRIMMORY, name = "AZW3 test fixture",
                    serverUrl = "http://127.0.0.1:${socket.localPort}", username = "", urlScheme = UrlScheme.HTTP,
                ))
                val resource = checkNotNull(component.aggregator().getEbookResource(id, bookSource, connectionId))
                assertEquals("AZW3", resource.format)
                assertEquals("777", resource.providerFileId)
            }
            var savedProgress = 0.0
            repeat(2) { opening ->
                ActivityScenario.launch<EbookReaderActivity>(intent).use { scenario ->
                    var navigator: ReaderEngineNavigator? = null
                    lateinit var viewModel: ReaderViewModel
                    withTimeout(60_000) {
                        while (navigator == null) {
                            scenario.onActivity { activity ->
                                val ready = EbookReaderActivity::class.java.getDeclaredField("foliateReady")
                                    .apply { isAccessible = true }.getBoolean(activity)
                                if (ready) {
                                    navigator = EbookReaderActivity::class.java.getDeclaredField("foliateEngine")
                                        .apply { isAccessible = true }.get(activity) as ReaderEngineNavigator
                                }
                                assertTrue(activity.supportFragmentManager.fragments.none { it is EpubNavigatorFragment })
                                viewModel = ViewModelProvider(activity)[ReaderViewModel::class.java]
                            }
                            delay(100)
                        }
                    }
                    val reader = checkNotNull(navigator)
                    assertEquals(ReaderEngineKind.FOLIATE, reader.kind)
                    withTimeout(15_000) {
                        while (reader.currentLocator == null) delay(100)
                    }
                    assertFalse("AZW3 must not be converted to EPUB", normalized.exists())
                    if (opening == 0) {
                        assertTrue(checkNotNull(reader.currentLocator?.locations?.totalProgression) >= 0.1)
                        val before = reader.currentLocator
                        withContext(Dispatchers.Main) { viewModel.pageForward() }
                        withTimeout(15_000) {
                            while (reader.currentLocator == before) delay(100)
                        }
                        savedProgress = checkNotNull(reader.currentLocator?.locations?.totalProgression)
                        assertTrue(savedProgress > 0.0)
                        InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot().let { screenshot ->
                            File(context.cacheDir, "azw3-reader-verification.png").outputStream().use {
                                screenshot.compress(Bitmap.CompressFormat.PNG, 100, it)
                            }
                            screenshot.recycle()
                        }
                    } else {
                        assertNotNull(reader.currentLocator?.locations?.totalProgression)
                        assertEquals(savedProgress, reader.currentLocator!!.locations.totalProgression!!, 0.05)
                    }
                    delay(1_000)
                }
            }
            if (connectionId != null) {
                assertTrue(requests.contains("/api/v1/books/$id/content?bookType=AZW3"))
            }
        } finally {
            if (connectionId != null) component.connections().remove(connectionId)
            socket?.close()
            worker?.join(2_000)
            source.delete()
            File(source.parentFile, "$id.777.azw3").delete()
            normalized.delete()
        }
    }
}
