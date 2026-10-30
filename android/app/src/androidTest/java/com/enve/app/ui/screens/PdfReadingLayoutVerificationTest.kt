package com.enve.app.ui.screens

import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import android.net.Uri
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assert
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performSemanticsAction
import androidx.lifecycle.Lifecycle
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.CachedBook
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.reader.PdfReadingLayout
import dagger.hilt.android.EntryPointAccessors
import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PdfReadingLayoutVerificationTest {
    @get:Rule val compose = createEmptyComposeRule()

    private val pageColors = intArrayOf(
        Color.rgb(230, 60, 60),
        Color.rgb(60, 170, 60),
        Color.rgb(60, 90, 230),
        Color.rgb(230, 190, 40),
        Color.rgb(170, 60, 200),
        Color.rgb(40, 190, 200),
    )

    @Test
    fun twoPageLayoutPairsPagesAndKeepsProgressOnTheSelectedPage() = runBlocking<Unit> {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use { await { coordinator.activeRuntime.value != null } }
        val component = checkNotNull(coordinator.activeRuntime.value).component
        val store = component.pdfReadingPreferencesStore()
        val bookCache = component.bookCacheDao()
        val connectionId = component.connections().connections.first().firstOrNull { it.enabled && it.source == BookSource.LOCAL }?.id
        val fixtureDir = File(context.cacheDir, "pdf-layout-fixture-${UUID.randomUUID()}").apply { mkdirs() }
        val fixtures = listOf("first", "second").map { name ->
            val file = File(fixtureDir, "$name.pdf")
            writeSixPagePdf(file, name)
            Fixture(Uri.fromFile(file).toString(), connectionId, "PDF layout $name")
        }
        val first = fixtures[0]
        val second = fixtures[1]
        try {
            bookCache.upsert(fixtures.map { it.book.toCachedBook() })
            assertEquals(PdfReadingLayout(), store.layout(first.key))

            ActivityScenario.launch<PdfReaderActivity>(first.intent(context)).use { scenario ->
                awaitText("Page 1 of 6")
                awaitContentDescription("PDF page 1 of 6")
                compose.onNodeWithContentDescription("Previous page").assertIsNotEnabled()
                compose.onNodeWithContentDescription("Next page").assertIsEnabled()
                val initial = bookCache.awaitProgress(first) { it.epubLocator?.contains("\"page\":1") == true }
                assertEquals(1f / 6f, initial.readProgress, 0.001f)

                compose.onNodeWithContentDescription("Appearance").performClick()
                awaitText("Two-page view")
                compose.onNodeWithText("Two-page view").assertIsOff()
                compose.onNodeWithText("Show cover separately").assertIsNotEnabled()
                compose.onNodeWithText("Two-page view").performClick()
                awaitText("Pages 1-2 of 6")
                awaitContentDescription("PDF pages 1-2 of 6")
                compose.onNodeWithText("Two-page view").assertIsOn()
                compose.onNodeWithText("Show cover separately").assertIsEnabled()
                compose.onNodeWithText("Show cover separately").assertIsOff()
                await { store.layout(first.key) == PdfReadingLayout(twoPageView = true) }
                compose.onNodeWithText("Done").performClick()
                awaitNoText("Done")
                compose.waitForIdle()
                delay(600)
                assertSpreadRendered("PDF pages 1-2 of 6", pageColors[0], pageColors[1], File(context.cacheDir, "pdf-layout-two-page.png"))

                delay(1500)
                val afterToggle = checkNotNull(bookCache.progress(first))
                assertEquals(initial.lastReadTime, afterToggle.lastReadTime)
                assertEquals(initial.epubLocator, afterToggle.epubLocator)

                compose.onNodeWithContentDescription("Appearance").performClick()
                awaitText("Show cover separately")
                compose.onNodeWithText("Show cover separately").performClick()
                awaitText("Page 1 of 6")
                awaitContentDescription("PDF page 1 of 6")
                await { store.layout(first.key) == PdfReadingLayout(twoPageView = true, showCoverSeparately = true) }
                compose.onNodeWithText("Done").performClick()
                awaitNoText("Done")

                compose.onNodeWithContentDescription("Next page").performClick()
                awaitText("Pages 2-3 of 6")
                awaitContentDescription("PDF pages 2-3 of 6")
                compose.waitForIdle()
                delay(600)
                assertSpreadRendered("PDF pages 2-3 of 6", pageColors[1], pageColors[2], File(context.cacheDir, "pdf-layout-cover-separately.png"))
                compose.onNodeWithContentDescription("Next page").performClick()
                awaitText("Pages 4-5 of 6")
                compose.onNodeWithContentDescription("Next page").performClick()
                awaitText("Page 6 of 6")
                awaitContentDescription("PDF page 6 of 6")
                compose.onNodeWithContentDescription("Next page").assertIsNotEnabled()
                val finished = bookCache.awaitProgress(first) { it.epubLocator?.contains("\"page\":6") == true }
                assertEquals(1f, finished.readProgress, 0.001f)

                compose.onNodeWithContentDescription("Previous page").performClick()
                awaitText("Pages 4-5 of 6")
                compose.onNodeWithContentDescription("Previous page").performClick()
                awaitText("Pages 2-3 of 6")
                compose.onNodeWithContentDescription("Previous page").performClick()
                awaitText("Page 1 of 6")
                awaitContentDescription("PDF page 1 of 6")
                compose.onNodeWithContentDescription("Previous page").assertIsNotEnabled()
                bookCache.awaitProgress(first) { it.epubLocator?.contains("\"page\":1") == true }

                compose.onNodeWithContentDescription("Page position")
                    .performSemanticsAction(SemanticsActions.SetProgress) { it(1f) }
                awaitText("Pages 2-3 of 6")
                compose.onNodeWithContentDescription("Page position")
                    .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Page 2 of 6"))
                val selectedSecond = bookCache.awaitProgress(first) { it.epubLocator?.contains("\"page\":2") == true }
                assertEquals(2f / 6f, selectedSecond.readProgress, 0.001f)

                compose.onNodeWithContentDescription("Appearance").performClick()
                awaitText("Two-page view")
                compose.onNodeWithText("Two-page view").performClick()
                awaitText("Page 2 of 6")
                awaitContentDescription("PDF page 2 of 6")
                compose.onNodeWithText("Show cover separately").assertIsNotEnabled()
                compose.onNodeWithText("Two-page view").performClick()
                awaitText("Pages 2-3 of 6")
                compose.onNodeWithText("Done").performClick()
                awaitNoText("Done")
                delay(1500)
                val afterRelayout = checkNotNull(bookCache.progress(first))
                assertEquals(selectedSecond.lastReadTime, afterRelayout.lastReadTime)
                assertEquals(selectedSecond.epubLocator, afterRelayout.epubLocator)

                scenario.moveToState(Lifecycle.State.STARTED)
                val paused = bookCache.awaitProgress(first) { it.lastReadTime != selectedSecond.lastReadTime }
                assertTrue(paused.epubLocator.orEmpty(), paused.epubLocator?.contains("\"page\":2") == true)
                assertEquals(2f / 6f, paused.readProgress, 0.001f)
                scenario.moveToState(Lifecycle.State.RESUMED)
                awaitText("Pages 2-3 of 6")

                scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
                await {
                    var landscape = false
                    scenario.onActivity { landscape = it.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE }
                    landscape
                }
                awaitText("Pages 2-3 of 6")
                awaitContentDescription("PDF pages 2-3 of 6")
                compose.onNodeWithContentDescription("Page position")
                    .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Page 2 of 6"))
                compose.waitForIdle()
                delay(800)
                screenshot(File(context.cacheDir, "pdf-layout-landscape.png"))
                scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
                await {
                    var portrait = false
                    scenario.onActivity { portrait = it.resources.configuration.orientation == Configuration.ORIENTATION_PORTRAIT }
                    portrait
                }
                awaitText("Pages 2-3 of 6")
                scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED }
            }

            bookCache.awaitProgress(first) { it.epubLocator?.contains("\"page\":2") == true }
            ActivityScenario.launch<PdfReaderActivity>(first.intent(context)).use {
                awaitText("Pages 2-3 of 6")
                awaitContentDescription("PDF pages 2-3 of 6")
                compose.onNodeWithContentDescription("Page position")
                    .assert(SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, "Page 2 of 6"))
                compose.onNodeWithContentDescription("Appearance").performClick()
                awaitText("Two-page view")
                compose.onNodeWithText("Two-page view").assertIsOn()
                compose.onNodeWithText("Show cover separately").assertIsOn()
                compose.onNodeWithText("Done").performClick()
                awaitNoText("Done")
            }

            assertEquals(PdfReadingLayout(), store.layout(second.key))
            ActivityScenario.launch<PdfReaderActivity>(second.intent(context)).use {
                awaitText("Page 1 of 6")
                awaitContentDescription("PDF page 1 of 6")
                compose.onNodeWithContentDescription("Appearance").performClick()
                awaitText("Two-page view")
                compose.onNodeWithText("Two-page view").assertIsOff()
                compose.onNodeWithText("Show cover separately").assertIsNotEnabled()
                compose.onNodeWithText("Done").performClick()
                awaitNoText("Done")
            }
            assertEquals(PdfReadingLayout(twoPageView = true, showCoverSeparately = true), store.layout(first.key))
        } finally {
            fixtures.forEach { fixture ->
                store.clear(fixture.key)
                component.lastOpenedBookStore().forget(fixture.key)
                File(component.storageLocations().cacheDirectory, "reader-files/${fixture.cachedName}.pdf").delete()
            }
            bookCache.deleteByCacheKeys(fixtures.map { it.key })
            fixtureDir.deleteRecursively()
        }
    }

    private class Fixture(val bookId: String, val connectionId: String?, val title: String) {
        val book = Book(
            id = bookId,
            title = title,
            author = "Enve tests",
            source = BookSource.LOCAL,
            mediaType = AppMediaType.EBOOK,
            connectionId = connectionId,
            hasEbook = true,
            primaryFileType = "pdf",
        )
        val key: String get() = book.uniqueKey
        val cachedName: String get() = bookId.replace(Regex("[^a-zA-Z0-9_-]"), "_")

        fun intent(context: Context) = PdfReaderActivity.createIntent(
            context, bookId, BookSource.LOCAL, connectionId, title, "Enve tests", locator = null,
        )
    }

    private suspend fun BookCacheDao.progress(fixture: Fixture): CachedBook? =
        getByIdAndConnection(fixture.bookId, fixture.connectionId)

    private suspend fun BookCacheDao.awaitProgress(fixture: Fixture, condition: (CachedBook) -> Boolean): CachedBook {
        await(description = { "Progress for ${fixture.title} did not reach the expected state" }) {
            progress(fixture)?.let(condition) == true
        }
        return checkNotNull(progress(fixture))
    }

    private fun awaitText(text: String) {
        compose.waitUntil(20_000) { compose.onAllNodes(hasText(text)).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun awaitNoText(text: String) {
        compose.waitUntil(20_000) { compose.onAllNodes(hasText(text)).fetchSemanticsNodes().isEmpty() }
    }

    private fun awaitContentDescription(description: String) {
        compose.waitUntil(20_000) { compose.onAllNodes(hasContentDescription(description)).fetchSemanticsNodes().isNotEmpty() }
    }

    private fun screenshot(output: File): Bitmap {
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        output.outputStream().use { stream -> bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream) }
        return bitmap
    }

    private fun assertSpreadRendered(description: String, leftColor: Int, rightColor: Int, output: File) {
        val bounds = compose.onNodeWithContentDescription(description).fetchSemanticsNode().boundsInWindow
        val spreadAspect = (2 * PAGE_WIDTH).toFloat() / PAGE_HEIGHT
        val drawnWidth = minOf(bounds.width, bounds.height * spreadAspect)
        val drawnHeight = drawnWidth / spreadAspect
        val left = bounds.left + (bounds.width - drawnWidth) / 2f
        val top = bounds.top + (bounds.height - drawnHeight) / 2f
        val shot = screenshot(output)
        val y = (top + drawnHeight * 0.7f).roundToInt().coerceIn(0, shot.height - 1)
        val leftSample = shot.getPixel((left + drawnWidth * 0.25f).roundToInt().coerceIn(0, shot.width - 1), y)
        val rightSample = shot.getPixel((left + drawnWidth * 0.75f).roundToInt().coerceIn(0, shot.width - 1), y)
        assertTrue("Left page pixel ${Integer.toHexString(leftSample)} did not match ${Integer.toHexString(leftColor)}", closeTo(leftSample, leftColor))
        assertTrue("Right page pixel ${Integer.toHexString(rightSample)} did not match ${Integer.toHexString(rightColor)}", closeTo(rightSample, rightColor))
    }

    private fun closeTo(actual: Int, expected: Int): Boolean =
        abs(Color.red(actual) - Color.red(expected)) <= 48 &&
            abs(Color.green(actual) - Color.green(expected)) <= 48 &&
            abs(Color.blue(actual) - Color.blue(expected)) <= 48

    private fun writeSixPagePdf(file: File, name: String) {
        val document = PdfDocument()
        val fill = Paint()
        val ink = Paint().apply {
            color = Color.BLACK
            textSize = 48f
            isAntiAlias = true
            textAlign = Paint.Align.CENTER
        }
        try {
            for (index in 0 until 6) {
                val page = document.startPage(PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, index + 1).create())
                val canvas: Canvas = page.canvas
                fill.color = pageColors[index]
                canvas.drawRect(0f, 0f, PAGE_WIDTH.toFloat(), PAGE_HEIGHT.toFloat(), fill)
                canvas.drawText("$name page ${index + 1}", PAGE_WIDTH / 2f, PAGE_HEIGHT * 0.2f, ink)
                document.finishPage(page)
            }
            file.outputStream().use { document.writeTo(it) }
        } finally {
            document.close()
        }
    }

    private suspend fun await(description: () -> String = { "Reader did not reach the expected state" }, condition: suspend () -> Boolean) {
        val deadline = android.os.SystemClock.elapsedRealtime() + 20_000
        while (!condition()) {
            check(android.os.SystemClock.elapsedRealtime() < deadline) { description() }
            delay(100)
        }
    }

    private companion object {
        const val PAGE_WIDTH = 612
        const val PAGE_HEIGHT = 792
    }
}
