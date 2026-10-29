package com.enve.app.ui.screens

import android.content.Context
import androidx.compose.ui.test.hasClickAction
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.app.viewmodel.ReaderViewModel
import com.enve.core.data.model.BookSource
import com.enve.core.reader.ReaderEngineKind
import dagger.hilt.android.EntryPointAccessors
import java.io.File
import java.util.UUID
import java.util.zip.CRC32
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReaderTtsPlaybackTest {
    @get:Rule
    val compose = createEmptyComposeRule()

    @Test
    fun readiumSpeechKeepsNormalControlsAccessible() = verify(ReaderEngineKind.READIUM)

    @Test
    fun foliateSpeechKeepsNormalControlsAccessible() = verify(ReaderEngineKind.FOLIATE)

    private fun click(description: String) =
        compose.onNode(hasContentDescription(description) and hasClickAction()).performClick()

    private fun verify(engine: ReaderEngineKind) = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use { await { coordinator.activeRuntime.value != null } }
        val runtime = checkNotNull(coordinator.activeRuntime.value)
        val id = "tts-controls-${UUID.randomUUID()}"
        val file = File(runtime.component.storageLocations().cacheDirectory, "ebooks/$id.epub")
        file.parentFile!!.mkdirs()
        writeBook(file)
        val intent = EbookReaderActivity.createIntent(context, id, BookSource.LOCAL,
            title = "Enve speech verification", author = "Enve tests", bookFormat = "EPUB",
            epubLocator = null, epubProgress = 0f, readerEngine = engine)
        try {
            ActivityScenario.launch<EbookReaderActivity>(intent).use { scenario ->
                lateinit var vm: ReaderViewModel
                await {
                    scenario.onActivity { vm = ViewModelProvider(it)[ReaderViewModel::class.java] }
                    vm.state.value.isReady && vm.state.value.ttsReady && vm.state.value.totalPages > 0
                }
                val original = vm.state.value.prefs
                try {
                    withContext(Dispatchers.Main) { if (!vm.state.value.showChrome) vm.toggleChrome() }
                    click("Read back")
                    await { vm.state.value.ttsPlayback.playing && !vm.state.value.ttsPlayback.preparing }
                    click("Pause read back")
                    await { vm.state.value.ttsPlayback.active && !vm.state.value.ttsPlayback.playing }
                    val paragraph = vm.state.value.ttsPlayback.paragraph
                    click("Next paragraph")
                    await { vm.state.value.ttsPlayback.paragraph == paragraph + 1 }
                    assertFalse(vm.state.value.ttsPlayback.playing)
                    click("Previous paragraph")
                    assertEquals(paragraph, vm.state.value.ttsPlayback.paragraph)

                    withContext(Dispatchers.Main) { vm.hideChrome() }
                    click("Show reader controls")
                    assertTrue(vm.state.value.showChrome)
                    assertTrue(vm.state.value.ttsPlayback.active)
                    assertFalse(vm.state.value.ttsPlayback.playing)
                    click("Voice and speed")
                    compose.onNodeWithText("1.25×").performClick()
                    assertEquals(1.25f, vm.state.value.prefs.ttsSpeed, 0.001f)
                    assertFalse(vm.state.value.ttsPlayback.playing)
                    assertTrue(vm.state.value.ttsVoices.isNotEmpty())
                    delay(5_200)
                    assertTrue(vm.state.value.showChrome)
                    assertTrue(vm.state.value.showTtsSheet)
                    compose.onNodeWithText("Done").performClick()
                    click("Resume read back")
                    await { vm.state.value.ttsPlayback.playing && !vm.state.value.ttsPlayback.preparing }
                    click("Contents")
                    assertTrue(vm.state.value.showTocSheet)
                    assertTrue(vm.state.value.ttsPlayback.playing)
                    withContext(Dispatchers.Main) { vm.showToc(false); vm.pauseTts() }
                    val directory = File(context.getExternalFilesDir(null), "parity-verification").apply { mkdirs() }
                    InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot().let { bitmap ->
                        File(directory, "reader-$engine.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                        bitmap.recycle()
                    }
                } finally {
                    withContext(Dispatchers.Main) { vm.stopTts(); vm.updatePreferences(original); vm.flushPreferences() }
                    withTimeout(5_000) { runtime.component.preferences().readerTtsSpeed.first { it == original.ttsSpeed } }
                }
            }
        } finally {
            file.delete()
        }
    }

    private suspend fun await(predicate: () -> Boolean) = withTimeout(30_000) {
        while (!predicate()) delay(100)
    }

    private fun writeBook(file: File) {
        ZipOutputStream(file.outputStream()).use { zip ->
            fun entry(path: String, value: String, stored: Boolean = false) {
                val bytes = value.toByteArray()
                val entry = ZipEntry(path)
                if (stored) {
                    entry.method = ZipEntry.STORED
                    entry.size = bytes.size.toLong()
                    entry.crc = CRC32().apply { update(bytes) }.value
                }
                zip.putNextEntry(entry)
                zip.write(bytes)
                zip.closeEntry()
            }
            entry("mimetype", "application/epub+zip", stored = true)
            entry("META-INF/container.xml", """<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""")
            entry("OPS/book.opf", """<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">enve-tts-verification</dc:identifier><dc:title>Enve speech verification</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">2026-10-24T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="one" href="one.xhtml" media-type="application/xhtml+xml"/><item id="two" href="two.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="one"/><itemref idref="two"/></spine></package>""")
            entry("OPS/nav.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head><body><nav epub:type="toc"><ol><li><a href="one.xhtml">First chapter</a></li><li><a href="two.xhtml">Second chapter</a></li></ol></nav></body></html>""")
            for (chapter in listOf("one", "two")) {
                val paragraphs = (1..6).joinToString("") { index ->
                    "<p>Paragraph $index. " + "The orange book rests beside a window while the reader explores another story. ".repeat(30) + "</p>"
                }
                entry("OPS/$chapter.xhtml", """<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter $chapter</title></head><body>$paragraphs</body></html>""")
            }
        }
    }
}
