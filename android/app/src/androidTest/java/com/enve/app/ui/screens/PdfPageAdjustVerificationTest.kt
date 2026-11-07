package com.enve.app.ui.screens

import android.content.Context
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfDocument
import android.net.Uri
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.doubleClick
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.swipeDown
import androidx.compose.ui.test.swipeLeft
import androidx.compose.ui.test.swipeRight
import androidx.compose.ui.test.swipeUp
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.core.data.local.PdfReadingPreferencesStore
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.reader.PdfPageAdjust
import dagger.hilt.android.EntryPointAccessors
import java.io.File
import java.util.UUID
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PdfPageAdjustVerificationTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val context get() = ApplicationProvider.getApplicationContext<Context>()

    @Test
    fun croppedPageEdgesAreReachableAndZoomResetsWithoutTurningPages() = withPdf { book, scenario, store ->
        awaitPage(1)
        assertTrue(capture("pdf-adjust-fit").all { it > 100 })
        choose(PdfPageAdjust.FILL_HEIGHT)
        page(1).performTouchInput { swipeRight() }
        assertTrue("Left printed edge remains clipped", capture("pdf-adjust-left")[0] > 100)
        page(1).performTouchInput { swipeLeft() }
        assertTrue("Right printed edge remains clipped", capture("pdf-adjust-right")[1] > 100)

        page(1).performTouchInput { doubleClick() }
        assertTrue(hasResetZoom(1))
        page(1).performTouchInput { doubleClick() }
        assertFalse(hasResetZoom(1))
        page(1).performTouchInput { doubleClick() }
        choose(PdfPageAdjust.FIT)
        assertFalse(hasResetZoom(1))
        assertTrue(capture("pdf-adjust-mode-reset").all { it > 100 })

        page(1).performTouchInput { doubleClick() }
        compose.onNodeWithContentDescription("Next page").performClick()
        awaitPage(2)
        assertFalse(hasResetZoom(2))
        assertTrue(capture("pdf-adjust-page-reset").all { it > 100 })
        compose.onNodeWithContentDescription("Previous page").performClick()
        awaitPage(1)

        page(1).performTouchInput { doubleClick() }
        scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
        compose.waitUntil(10_000) {
            var landscape = false
            scenario.onActivity { landscape = it.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE }
            landscape
        }
        compose.waitForIdle()
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        android.os.SystemClock.sleep(400)
        assertFalse(hasResetZoom(1))
        choose(PdfPageAdjust.FILL_WIDTH)
        repeat(8) { page(1).performTouchInput { swipeDown() } }
        assertTrue("Top printed edge remains clipped", capture("pdf-adjust-top")[2] > 100)
        repeat(8) { page(1).performTouchInput { swipeUp() } }
        assertTrue("Bottom printed edge remains clipped", capture("pdf-adjust-bottom")[3] > 100)
        awaitPage(1)

        scenario.recreate()
        awaitPage(1)
        compose.onNodeWithContentDescription("Appearance").performClick()
        awaitText("PAGE ADJUST")
        compose.onNodeWithText("Fill Width").performScrollTo().assertIsDisplayed()
        assertEquals(PdfPageAdjust.FILL_WIDTH, store.layout(book.uniqueKey).pageAdjust)
        compose.onNodeWithText("Done").performClick()
    }

    @Test
    fun everySizingChoiceCanBeSelectedAndTheSheetCanBeDismissed() = withPdf { book, _, store ->
        awaitPage(1)
        for (adjust in PdfPageAdjust.entries) {
            choose(adjust)
            withTimeout(5_000) {
                while (store.layout(book.uniqueKey).pageAdjust != adjust) delay(50)
            }
            awaitPage(1)
        }
        compose.onNodeWithContentDescription("Appearance").performClick()
        awaitText("PAGE ADJUST")
        compose.onNodeWithText("Fill Width").performScrollTo().assertIsDisplayed()
        capture("pdf-adjust-options")
        compose.onNodeWithText("Done").assertIsDisplayed().performClick()
    }

    private fun withPdf(
        block: suspend (Book, ActivityScenario<PdfReaderActivity>, PdfReadingPreferencesStore) -> Unit,
    ) = runBlocking<Unit> {
        val coordinator = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use {
            val deadline = android.os.SystemClock.elapsedRealtime() + 20_000
            while (coordinator.activeRuntime.value == null) {
                check(android.os.SystemClock.elapsedRealtime() < deadline)
                delay(50)
            }
        }
        val component = checkNotNull(coordinator.activeRuntime.value).component
        val store = component.pdfReadingPreferencesStore()
        val directory = File(context.cacheDir, "pdf-adjust-${UUID.randomUUID()}").apply { mkdirs() }
        val file = File(directory, "printed-edges.pdf")
        writePdf(file)
        val book = Book(
            id = Uri.fromFile(file).toString(), title = "PDF printed page edges", source = BookSource.LOCAL,
            mediaType = AppMediaType.EBOOK, primaryFileType = "pdf", hasEbook = true,
        )
        component.bookCacheDao().upsert(listOf(book.toCachedBook()))
        try {
            val intent = PdfReaderActivity.createIntent(context, book.id, BookSource.LOCAL, title = book.title, author = "Enve tests", locator = null)
            ActivityScenario.launch<PdfReaderActivity>(intent).use { scenario -> block(book, scenario, store) }
        } finally {
            store.clear(book.uniqueKey)
            component.lastOpenedBookStore().forget(book.uniqueKey)
            component.bookCacheDao().deleteByCacheKeys(listOf(book.uniqueKey))
            val cachedName = book.id.replace(Regex("[^a-zA-Z0-9_-]"), "_")
            File(component.storageLocations().cacheDirectory, "reader-files/$cachedName.pdf").delete()
            directory.deleteRecursively()
        }
    }

    private fun choose(adjust: PdfPageAdjust) {
        compose.onNodeWithContentDescription("Appearance").performClick()
        awaitText("PAGE ADJUST")
        compose.onNodeWithText(adjust.label).performScrollTo().assertIsDisplayed().performClick()
        compose.onNodeWithText("Done").assertIsDisplayed().performClick()
        compose.waitUntil(5_000) {
            compose.onAllNodes(hasText("Done")).fetchSemanticsNodes(atLeastOneRootRequired = false).isEmpty()
        }
        compose.waitForIdle()
    }

    private fun page(number: Int) = compose.onNodeWithContentDescription("PDF page $number of 2")

    private fun awaitPage(number: Int) = compose.waitUntil(20_000) {
        compose.onAllNodes(hasContentDescription("PDF page $number of 2")).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
    }

    private fun awaitText(value: String) = compose.waitUntil(10_000) {
        compose.onAllNodes(hasText(value)).fetchSemanticsNodes(atLeastOneRootRequired = false).isNotEmpty()
    }

    private fun hasResetZoom(number: Int): Boolean =
        page(number).fetchSemanticsNode().config[SemanticsActions.CustomActions].any { it.label == "Reset zoom" }

    private fun capture(name: String): IntArray {
        compose.waitForIdle()
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        android.os.SystemClock.sleep(200)
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        File(context.cacheDir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        val counts = IntArray(4)
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        pixels.forEach { color ->
            val r = Color.red(color)
            val g = Color.green(color)
            val b = Color.blue(color)
            if (r > 210 && g < 45 && b < 45) counts[0]++
            if (g > 150 && r < 45 && b < 45) counts[1]++
            if (b > 210 && r < 45 && g < 45) counts[2]++
            if (r > 210 && g > 190 && b < 45) counts[3]++
        }
        bitmap.recycle()
        return counts
    }

    private fun writePdf(file: File) {
        val document = PdfDocument()
        try {
            for (number in 1..2) {
                val page = document.startPage(PdfDocument.PageInfo.Builder(612, 792, number).create())
                val paint = Paint()
                page.canvas.drawColor(Color.WHITE)
                paint.color = Color.RED
                page.canvas.drawRect(35f, 320f, 65f, 470f, paint)
                paint.color = Color.GREEN
                page.canvas.drawRect(547f, 320f, 577f, 470f, paint)
                paint.color = Color.BLUE
                page.canvas.drawRect(220f, 35f, 390f, 65f, paint)
                paint.color = Color.YELLOW
                page.canvas.drawRect(220f, 727f, 390f, 757f, paint)
                paint.color = Color.BLACK
                paint.textSize = 20f
                page.canvas.drawText("Printed content near every page edge", 110f, 140f, paint)
                page.canvas.drawText("Page $number", 260f, 400f, paint)
                document.finishPage(page)
            }
            file.outputStream().use(document::writeTo)
        } finally {
            document.close()
        }
    }
}
