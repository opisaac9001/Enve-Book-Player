package com.enve.app.listeningposition

import android.content.Context
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.profiles.DaggerProfileRuntimeComponent
import com.enve.app.profiles.ProfileResources
import com.enve.app.profiles.ProfileViewModelFactory
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.hearth.design.HearthTheme
import com.enve.hearth.detail.BookDetailScreen
import com.enve.hearth.shell.LocalProfileViewModelFactory
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ListeningPositionDetailsMenuTest {
    @get:Rule val compose = createComposeRule()

    @Test fun bookDetailsThreeDotMenuOpensTheShareCode() = verifyDetails(Book("audio-location", "Audio Location", duration = 3600, currentTime = 300, source = BookSource.LOCAL))

    @Test fun ebookDetailsMenuSharesAReadingPercentage() = verifyDetails(Book("epub-location", "EPUB Location", mediaType = AppMediaType.EBOOK,
        primaryFileType = "EPUB", epubProgress = 0.25f, source = BookSource.LOCAL), "25.0%")

    @Test fun pdfDetailsMenuSharesTheSavedPage() = verifyDetails(Book("pdf-location", "PDF Location", mediaType = AppMediaType.EBOOK,
        primaryFileType = "PDF", epubProgress = 0.25f, epubLocator = "{\"page\":5}", pageCount = 20, source = BookSource.LOCAL), "Page 5 of 20")

    @Test fun comicDetailsMenuSharesTheSavedPage() = verifyDetails(Book("comic-location", "Comic Location", mediaType = AppMediaType.EBOOK,
        primaryFileType = "CBZ", epubProgress = 0.25f, epubLocator = "cbz-page:5", pageCount = 20, source = BookSource.LOCAL), "Page 5 of 20")

    private fun verifyDetails(book: Book, expectedPosition: String? = null): Unit = runBlocking {
        val resources = ProfileResources.open(ApplicationProvider.getApplicationContext<Context>(), UUID.randomUUID().toString())
        val component = DaggerProfileRuntimeComponent.factory().create(resources)
        val factory = ProfileViewModelFactory(component)
        val visible = mutableStateOf(true)
        try {
            component.bookCacheDao().upsert(listOf(book.toCachedBook()))
            compose.setContent {
                CompositionLocalProvider(LocalProfileViewModelFactory provides factory) {
                    HearthTheme {
                        if (visible.value) BookDetailScreen(book, onBack = {}, onListen = { error("Sharing must not start playback") },
                            onRead = { error("Sharing must not open the reader") }, onOpenBook = {})
                    }
                }
            }
            compose.onNodeWithContentDescription("More").performScrollTo().performClick()
            compose.onNodeWithText("Share book location").performClick()
            compose.waitUntil(10000) { compose.onAllNodesWithTag("listening-position-qr").fetchSemanticsNodes().isNotEmpty() }
            expectedPosition?.let { compose.onNodeWithText(it).assertExists() }
            compose.onNodeWithText("Share image").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Close").performScrollTo().performClick()
            compose.onNodeWithContentDescription("More").assertExists()
        } finally {
            compose.runOnIdle { visible.value = false }
            factory.retire()
            resources.close()
            resources.locations.filesDirectory.deleteRecursively()
            resources.locations.cacheDirectory.deleteRecursively()
            resources.locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }
}
