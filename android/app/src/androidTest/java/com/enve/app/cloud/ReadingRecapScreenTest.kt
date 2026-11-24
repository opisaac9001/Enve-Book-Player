package com.enve.app.cloud

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.test.core.app.ApplicationProvider
import android.accessibilityservice.AccessibilityService
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import com.enve.engine.library.LibraryFacade
import com.enve.hearth.design.HearthTheme
import com.enve.hearth.journal.HearthReadingRecapScreen
import com.enve.hearth.journal.ReadingRecapViewModel
import com.enve.hearth.shell.LocalProfileViewModelFactory
import java.io.File
import java.lang.reflect.Proxy
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flowOf
import org.junit.Assert.assertNotNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReadingRecapScreenTest {
    @get:Rule val compose = createComposeRule()

    @Test
    fun switchesPeriodsAndProducesShareablePng() {
        val today = LocalDate.now()
        val previous = today.minusMonths(1)
        val book = Book(id = "recap-fixture", title = "Recap fixture", source = BookSource.LOCAL, mediaType = AppMediaType.EBOOK)
        val sessions = MutableStateFlow(listOf(session(today, "current", book), session(previous, "previous", book)))
        val library = Proxy.newProxyInstance(LibraryFacade::class.java.classLoader, arrayOf(LibraryFacade::class.java)) { _, method, _ ->
            when (method.name) {
                "getHistorySessions" -> sessions
                "bookByKeyFlow" -> flowOf(book)
                else -> error("Unexpected library operation: ${method.name}")
            }
        } as LibraryFacade
        val factory = object : ViewModelProvider.Factory {
            override fun <T : ViewModel> create(modelClass: Class<T>): T = modelClass.cast(ReadingRecapViewModel(library))!!
        }
        compose.setContent {
            CompositionLocalProvider(LocalProfileViewModelFactory provides factory) {
                HearthTheme { HearthReadingRecapScreen(onBack = {}, onSelectBook = {}) }
            }
        }
        compose.waitUntil(10_000) { compose.onAllNodesWithText("Month").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithContentDescription("Previous month").performClick()
        compose.onNodeWithText(previous.format(DateTimeFormatter.ofPattern("LLLL yyyy", Locale.getDefault()))).assertIsDisplayed()
        compose.onNodeWithText("Year").performClick()
        compose.onNodeWithText(previous.year.toString()).assertIsDisplayed()
        compose.onNodeWithText("Month").performClick()
        val context = ApplicationProvider.getApplicationContext<Context>()
        val directory = File(context.cacheDir, "reading-recap-share")
        val before = directory.listFiles().orEmpty().map { it.name }.toSet()
        compose.onNodeWithText("Share image").performScrollTo().performClick()
        compose.waitUntil(10_000) {
            directory.listFiles().orEmpty().any {
                it.name !in before && it.readBytes().takeLast(8).toByteArray()
                    .contentEquals(byteArrayOf(73, 69, 78, 68, -82, 66, 96, -126))
            }
        }
        val shared = directory.listFiles().orEmpty().first { it.name !in before }
        val bitmap = BitmapFactory.decodeFile(shared.absolutePath)
        assertNotNull(bitmap)
        bitmap?.recycle()
        InstrumentationRegistry.getInstrumentation().uiAutomation.performGlobalAction(AccessibilityService.GLOBAL_ACTION_BACK)
        shared.delete()
    }

    private fun session(day: LocalDate, id: String, book: Book): HistorySession {
        val end = day.atStartOfDay(ZoneId.systemDefault()).toInstant().toEpochMilli()
        return HistorySession(
            id = id, bookId = book.id, bookKey = book.uniqueKey, source = book.source,
            mediaType = AppMediaType.EBOOK, startTimeMs = end - 60_000, endTimeMs = end,
            activeDurationSeconds = 60,
        )
    }
}
