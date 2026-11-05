package com.enve.app.ui.screens

import android.content.Context
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithContentDescription
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileRuntimeComponent
import com.enve.app.profiles.ProfileRuntimeRegistry
import com.enve.app.profiles.ProfileViewModelFactory
import com.enve.app.viewmodel.LibraryViewModel
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookCardStyle
import com.enve.core.data.model.BookSource
import com.enve.hearth.design.HearthTheme
import com.enve.hearth.library.HearthLibraryScreen
import com.enve.hearth.library.HearthLibraryViewModel
import com.enve.hearth.library.StatusFilter
import com.enve.hearth.shell.LocalProfileViewModelFactory
import java.util.UUID
import kotlinx.coroutines.Dispatchers
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
class LocalLibraryPresentationRegressionTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun coverOnlyPersistsAcrossProfileReopenAndReachesLocalLibraryTiles(): Unit = runBlocking {
        withProfile { runtimes, profileId, initial ->
            val book = localBook()
            initial.bookCacheDao().upsert(listOf(book.toCachedBook()))
            val initialFactory = ProfileViewModelFactory(initial)
            try {
                withContext(Dispatchers.Main) {
                    initialFactory.create(LibraryViewModel::class.java).setBookCardStyle(BookCardStyle.COVER_ONLY)
                }
                withTimeout(5_000) { initial.preferencesFacade().bookCardStyle.first { it == BookCardStyle.COVER_ONLY } }
            } finally {
                initialFactory.retire()
            }
            runtimes.close(profileId)
            val reopened = runtimes.open(profileId)
            assertEquals(BookCardStyle.COVER_ONLY, reopened.preferencesFacade().bookCardStyle.first())
            reopened.preferencesFacade().setLibraryColumns(2)
            withLibrary(reopened) { factory, vm ->
                compose.waitUntil(5_000) { vm.cardStyle.value == BookCardStyle.COVER_ONLY && vm.books.value.any { it.uniqueKey == book.uniqueKey } }
                compose.onNodeWithContentDescription(book.title, substring = true).assertIsDisplayed()
                compose.onNodeWithText(book.title).assertDoesNotExist()
                compose.onNodeWithText(book.author!!).assertDoesNotExist()
                withContext(Dispatchers.Main) {
                    factory.create(LibraryViewModel::class.java).setBookCardStyle(BookCardStyle.STANDARD)
                }
                withTimeout(5_000) { reopened.preferencesFacade().bookCardStyle.first { it == BookCardStyle.STANDARD } }
                compose.waitUntil(5_000) { compose.onAllNodesWithText(book.title).fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithText(book.title).assertIsDisplayed()
                compose.onNodeWithText(book.author!!).assertIsDisplayed()
            }
        }
    }

    @Test
    fun localProgressAndMetadataPublishToCurrentlyReadingAndContinue(): Unit = runBlocking {
        withProfile { _, _, component ->
            val book = localBook()
            component.bookCacheDao().upsert(listOf(book.toCachedBook()))
            val library = component.library()
            assertFalse(library.continueBooks.first().any { it.uniqueKey == book.uniqueKey })
            withLibrary(component, StatusFilter.CURRENTLY_READING) { _, _ ->
                compose.onNodeWithText("Nothing matches this filter.").assertIsDisplayed()
                assertEquals(1, component.bookCacheDao().updateUnifiedProgress(
                    book.id, book.connectionId, 0.25f, 0, "{\"progression\":0.25}", System.currentTimeMillis(),
                ))
                val continuing = withTimeout(5_000) {
                    library.continueBooks.first { books -> books.any { it.uniqueKey == book.uniqueKey } }
                }.single { it.uniqueKey == book.uniqueKey }
                assertEquals(0.25f, continuing.epubProgress!!, 0.001f)
                compose.waitUntil(5_000) { compose.onAllNodesWithContentDescription(book.title, substring = true).fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithContentDescription(book.title, substring = true).assertIsDisplayed()
                val renamed = continuing.copy(title = "Updated local title", libraryName = "Renamed local folder")
                component.bookCacheDao().upsert(listOf(renamed.toCachedBook()))
                val current = withTimeout(5_000) {
                    library.allBooks.first { books -> books.any { it.uniqueKey == book.uniqueKey && it.title == renamed.title } }
                }.single { it.uniqueKey == book.uniqueKey }
                assertEquals(renamed.libraryName, current.libraryName)
                compose.waitUntil(5_000) { compose.onAllNodesWithContentDescription(renamed.title, substring = true).fetchSemanticsNodes().isNotEmpty() }
                compose.onNodeWithContentDescription(renamed.title, substring = true).assertIsDisplayed()
                compose.onNodeWithText(book.title).assertDoesNotExist()
                assertTrue(library.continueBooks.first().any { it.uniqueKey == book.uniqueKey && it.title == renamed.title })
            }
        }
    }

    private fun localBook() = Book(
        id = "local-presentation-${UUID.randomUUID()}", title = "Local presentation fixture", author = "Local fixture author",
        source = BookSource.LOCAL, mediaType = AppMediaType.EBOOK, primaryFileType = "EPUB", hasEbook = true,
        libraryId = "local-presentation-folder", libraryName = "Local fixture folder", addedOn = System.currentTimeMillis(),
    )

    private suspend fun withLibrary(
        component: ProfileRuntimeComponent,
        status: StatusFilter = StatusFilter.ALL,
        block: suspend (ProfileViewModelFactory, HearthLibraryViewModel) -> Unit,
    ) {
        val factory = ProfileViewModelFactory(component)
        val owner = object : ViewModelStoreOwner { override val viewModelStore = ViewModelStore() }
        try {
            val vm = withContext(Dispatchers.Main) {
                ViewModelProvider(owner, factory)[HearthLibraryViewModel::class.java].also {
                    it.setSourceFilter(BookSource.LOCAL)
                    it.setStatus(status)
                }
            }
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    activity.setContent {
                        CompositionLocalProvider(LocalProfileViewModelFactory provides factory, LocalViewModelStoreOwner provides owner) {
                            HearthTheme { HearthLibraryScreen(covered = false, onSelectBook = {}) }
                        }
                    }
                }
                compose.waitForIdle()
                compose.waitUntil(10_000) { vm.totalCount.value == 1 }
                block(factory, vm)
            }
        } finally {
            withContext(Dispatchers.Main) { owner.viewModelStore.clear() }
            factory.retire()
        }
    }

    private suspend fun withProfile(block: suspend (ProfileRuntimeRegistry, String, ProfileRuntimeComponent) -> Unit) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val profileId = UUID.randomUUID().toString()
        val runtimes = ProfileRuntimeRegistry(context)
        val component = runtimes.open(profileId)
        val locations = component.storageLocations()
        try {
            block(runtimes, profileId, component)
        } finally {
            runtimes.close(profileId)
            locations.filesDirectory.deleteRecursively()
            locations.cacheDirectory.deleteRecursively()
            locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }
}
