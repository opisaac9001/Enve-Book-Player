package com.enve.app.ui.screens

import android.content.Context
import android.graphics.Bitmap
import android.os.SystemClock
import androidx.activity.compose.setContent
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasAnySibling
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isOff
import androidx.compose.ui.test.isOn
import androidx.compose.ui.test.isSelected
import androidx.compose.ui.test.isToggleable
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.longClick
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTouchInput
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.ViewModelStoreOwner
import androidx.lifecycle.viewmodel.compose.LocalViewModelStoreOwner
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.Espresso.pressBack
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileRuntimeRegistry
import com.enve.app.profiles.ProfileViewModelFactory
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ComicMetadata
import com.enve.core.data.model.ComicSection
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.UrlScheme
import com.enve.engine.prefs.HearthStartTab
import com.enve.engine.prefs.PreferencesFacade
import com.enve.hearth.library.HearthLibraryViewModel
import com.enve.hearth.library.MediaFilter
import com.enve.hearth.shell.HearthRoot
import com.enve.hearth.shell.LocalProfileViewModelFactory
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryComicSectionsAndAudiobooksOnlyTest {
    @get:Rule val compose = createEmptyComposeRule()

    private val tag = UUID.randomUUID().toString().take(8)
    private val now = System.currentTimeMillis()
    private val seriesName = "Night Ledger $tag"
    private val runA = "comic-run-a-$tag"
    private val runB = "comic-run-b-$tag"

    private val issueOne = comic(runA, 1986, "Ledger first issue $tag", ComicMetadata(SERIES_ID, issueLabel = "#1", issueOrder = 1.0))
    private val issueTwo = comic(runA, 1986, "Ledger second issue $tag", ComicMetadata(SERIES_ID, issueLabel = "#2", issueOrder = 2.0))
    private val volumeOne = comic(
        runA, 1986, "Ledger collected one $tag",
        ComicMetadata(SERIES_ID, ComicSection.VOLUMES, volumeId = "vol-1", volumeOrder = 1.0, issueLabel = "Vol. 1"),
    )
    private val volumeTwo = comic(
        runA, 1986, "Ledger collected two $tag",
        ComicMetadata(SERIES_ID, ComicSection.VOLUMES, volumeId = "vol-2", volumeOrder = 2.0, issueLabel = "Vol. 2"),
    )
    private val annual = comic(runA, 1986, "Ledger annual $tag", ComicMetadata(SERIES_ID, ComicSection.SPECIALS, issueLabel = "Annual 1"))
    private val reboot = comic(runB, 2011, "Ledger reboot issue $tag", ComicMetadata(SERIES_ID, issueLabel = "#1", issueOrder = 1.0))
    private val audiobook = Book(
        id = "audio-$tag", title = "Ledger audiobook $tag", author = "Fixture author",
        source = BookSource.AUDIOBOOKSHELF, mediaType = AppMediaType.AUDIOBOOK, hasAudio = true, duration = 3_600_000L,
        libraryId = "audio-library-$tag", libraryName = "Fixture audiobooks", connectionId = "audio-$tag", addedOn = now,
    )
    private val novel = Book(
        id = "novel-$tag", title = "Ledger novel $tag", author = "Fixture author",
        source = BookSource.GRIMMORY, mediaType = AppMediaType.EBOOK, primaryFileType = "EPUB", hasEbook = true,
        libraryId = "novel-library-$tag", libraryName = "Fixture ebooks", connectionId = "novel-$tag", addedOn = now - 1,
    )
    private val fixtures = listOf(audiobook, novel, issueOne, issueTwo, volumeOne, volumeTwo, annual, reboot)

    @Test
    fun sameNameRunsOpenIssueSpecialAndVolumeSectionsAndKeepTheirScopeAfterDetails(): Unit = runBlocking {
        withShell { library, _ ->
            enterComics(library)
            assertEquals(2, library.comicSeries.value.filter { it.name == seriesName }.map { it.key }.distinct().size)
            series(1986).assertIsDisplayed()
            series(2011).assertIsDisplayed()
            screenshot("comic-series")

            series(1986).performClick()
            compose.waitUntil(5_000) { library.comicSeriesView.value?.let { it.name == seriesName && it.total == 5 } == true }
            compose.onNodeWithText("5 issues · 5 unread").assertIsDisplayed()
            awaitSelectedSection("Issues, 2 issues")
            awaitIssue(issueOne)
            awaitIssue(issueTwo)
            assertAbsent(annual)
            compose.onNodeWithText("Volume 1").assertDoesNotExist()

            compose.onNodeWithContentDescription("Specials, 1 issue").performClick()
            awaitSelectedSection("Specials, 1 issue")
            awaitIssue(annual)
            assertAbsent(issueOne)

            compose.onNodeWithContentDescription("Volumes, 2 issues").performClick()
            awaitSelectedSection("Volumes, 2 issues")
            awaitVolume("Volume 1", COLLAPSED)
            awaitVolume("Volume 2", COLLAPSED)
            assertAbsent(volumeOne)
            assertAbsent(volumeTwo)

            compose.onNodeWithText("Volume 1").performClick()
            awaitVolume("Volume 1", EXPANDED)
            awaitIssue(volumeOne)
            assertAbsent(volumeTwo)
            screenshot("comic-sections")
            val chosen = library.comicBrowse.value

            compose.onNode(issue(volumeOne)).performTouchInput { longClick() }
            await(hasText("Details"))
            compose.onNodeWithText("Details").performClick()
            await(hasContentDescription("Back"))
            pressBack()
            compose.waitUntil(5_000) { !exists(hasContentDescription("Back")) }

            assertEquals(chosen, library.comicBrowse.value)
            assertEquals(ComicSection.VOLUMES, chosen.section)
            awaitSelectedSection("Volumes, 2 issues")
            awaitVolume("Volume 1", EXPANDED)
            awaitVolume("Volume 2", COLLAPSED)
            awaitIssue(volumeOne)

            compose.onNodeWithText("‹ Back").performClick()
            compose.waitUntil(5_000) { library.comicSeriesView.value == null }
            series(2011).performClick()
            compose.waitUntil(5_000) { library.comicSeriesView.value?.let { it.name == seriesName && it.total == 1 } == true }
            compose.onNodeWithText("1 issue · 1 unread").assertIsDisplayed()
            awaitIssue(reboot)
            assertAbsent(issueOne)
            compose.onNodeWithContentDescription("Volumes, 2 issues").assertDoesNotExist()
        }
    }

    @Test
    fun audiobooksOnlyShowsAudioHidesReadingAndRestoresComicChoices(): Unit = runBlocking {
        withShell { library, prefs ->
            compose.waitUntil(5_000) { library.books.value.size == fixtures.size }
            await(hasContentDescription(audiobook.title, substring = true))
            await(hasContentDescription(novel.title, substring = true))

            enterComics(library)
            series(1986).performClick()
            awaitSelectedSection("Issues, 2 issues")
            compose.onNodeWithContentDescription("Volumes, 2 issues").performClick()
            awaitSelectedSection("Volumes, 2 issues")
            compose.onNodeWithText("Volume 2").performClick()
            awaitVolume("Volume 2", EXPANDED)
            awaitIssue(volumeTwo)
            val chosen = library.comicBrowse.value

            toggleAudiobooksOnlyInSettings(on = true)
            compose.waitUntil(5_000) {
                !library.readingEnabled.value && library.effectiveMedia.value == MediaFilter.ALL &&
                    library.books.value.map(Book::uniqueKey) == listOf(audiobook.uniqueKey)
            }
            assertEquals(false, prefs.readingEnabled.first())
            await(hasContentDescription(audiobook.title, substring = true))
            listOf(novel, issueOne, volumeTwo, reboot).forEach(::assertAbsent)
            compose.onNodeWithContentDescription("Volumes, 2 issues").assertDoesNotExist()
            assertNull(library.comicSeriesView.value)

            compose.onNodeWithContentDescription("Filter & Sort").performClick()
            compose.onNodeWithText("Audiobooks").performScrollTo().assertIsDisplayed()
            listOf("Ebooks", "Comics", "Reading ebooks").forEach { compose.onNodeWithText(it).assertDoesNotExist() }
            compose.onNodeWithText("Done").performScrollTo().performClick()

            toggleAudiobooksOnlyInSettings(on = false)
            compose.waitUntil(5_000) {
                library.effectiveMedia.value == MediaFilter.COMICS &&
                    library.comicSeriesView.value?.selectedSection == ComicSection.VOLUMES
            }
            assertEquals(true, prefs.readingEnabled.first())
            assertEquals(chosen, library.comicBrowse.value)
            assertEquals(MediaFilter.COMICS.name, prefs.libraryMedia.first())
            awaitSelectedSection("Volumes, 2 issues")
            awaitVolume("Volume 2", EXPANDED)
            awaitVolume("Volume 1", COLLAPSED)
            awaitIssue(volumeTwo)
            assertAbsent(volumeOne)
        }
    }

    private fun enterComics(library: HearthLibraryViewModel) {
        compose.onNodeWithContentDescription("Filter & Sort").performClick()
        compose.onNodeWithText("Comics").performScrollTo().performClick()
        compose.onNodeWithText("Done").performScrollTo().performClick()
        compose.waitUntil(5_000) {
            library.effectiveMedia.value == MediaFilter.COMICS && library.comicSeries.value.count { it.name == seriesName } == 2
        }
    }

    private fun toggleAudiobooksOnlyInSettings(on: Boolean) {
        compose.onNodeWithContentDescription("More library options").performClick()
        compose.onNodeWithText("Settings").performClick()
        await(hasText("Library & reading"))
        compose.onNodeWithText("Library & reading").performScrollTo().performClick()
        await(hasText(AUDIOBOOKS_ONLY))
        val switch = audiobooksOnlySwitch()
        await(switch and if (on) isOff() else isOn())
        compose.onNode(switch).performClick()
        await(switch and if (on) isOn() else isOff())
        if (on) screenshot("audiobooks-only")
        compose.onNodeWithContentDescription("Back").performClick()
        compose.waitUntil(5_000) { !exists(hasText(AUDIOBOOKS_ONLY)) && exists(hasText("Library & reading")) }
        pressBack()
        compose.waitUntil(5_000) { !exists(hasContentDescription("Back")) && !exists(hasText("Library & reading")) }
    }

    private fun audiobooksOnlySwitch(): SemanticsMatcher {
        val label = compose.onNodeWithText(AUDIOBOOKS_ONLY).fetchSemanticsNode().boundsInRoot
        return isToggleable() and hasAnySibling(hasText(AUDIOBOOKS_ONLY)) and
            SemanticsMatcher("in the $AUDIOBOOKS_ONLY row") { label.center.y in it.boundsInRoot.top..it.boundsInRoot.bottom }
    }

    private fun series(year: Int) = compose.onNodeWithContentDescription("$seriesName, $year", substring = true)

    private fun issue(book: Book) = hasContentDescription(book.title, substring = true)

    private fun awaitIssue(book: Book) = await(issue(book))

    private fun assertAbsent(book: Book) = compose.onNode(issue(book)).assertDoesNotExist()

    private fun awaitSelectedSection(description: String) = await(hasContentDescription(description) and isSelected())

    private fun awaitVolume(title: String, state: String) =
        await(hasText(title) and SemanticsMatcher.expectValue(SemanticsProperties.StateDescription, state))

    private fun await(matcher: SemanticsMatcher) = compose.waitUntil(5_000) { exists(matcher) }

    private fun exists(matcher: SemanticsMatcher) = compose.onAllNodes(matcher).fetchSemanticsNodes().isNotEmpty()

    private fun screenshot(name: String) {
        compose.waitForIdle()
        SystemClock.sleep(400)
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: return
        val directory = File(instrumentation.targetContext.cacheDir, "parity-preview").apply { mkdirs() }
        File(directory, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
    }

    private fun comic(connectionId: String, year: Int, title: String, metadata: ComicMetadata) = Book(
        id = "comic-${UUID.randomUUID()}", title = title, author = "Fixture writer",
        source = BookSource.KOMGA, mediaType = AppMediaType.EBOOK, primaryFileType = "CBZ", hasEbook = true,
        seriesName = seriesName, publishedDate = "$year-01-01",
        libraryId = "comics-$connectionId", libraryName = "Fixture comics", connectionId = connectionId,
        addedOn = now - 10, comic = metadata,
    )

    private suspend fun withShell(block: suspend (HearthLibraryViewModel, PreferencesFacade) -> Unit) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val profileId = UUID.randomUUID().toString()
        val runtimes = ProfileRuntimeRegistry(context)
        val component = runtimes.open(profileId)
        val locations = component.storageLocations()
        val factory = ProfileViewModelFactory(component)
        val owner = object : ViewModelStoreOwner { override val viewModelStore = ViewModelStore() }
        try {
            val prefs = component.preferencesFacade()
            prefs.setPreferredStartTab(HearthStartTab.LIBRARY)
            prefs.setLibraryColumns(1)
            fixtures.distinctBy(Book::connectionId).forEach { book ->
                component.connections().upsert(ProviderConnection(
                    id = checkNotNull(book.connectionId),
                    source = book.source,
                    name = "Fixture ${book.source.name}",
                    serverUrl = "http://127.0.0.1:1",
                    username = "",
                    urlScheme = UrlScheme.HTTP,
                ))
            }
            component.bookCacheDao().upsert(fixtures.map { it.toCachedBook() })
            assertEquals(fixtures.size, component.bookCacheDao().count())
            assertEquals(fixtures.map { it.id }.toSet(), withTimeout(10_000) { component.library().allBooks.first() }.map { it.id }.toSet())
            val library = withContext(Dispatchers.Main) {
                ViewModelProvider(owner, factory)[HearthLibraryViewModel::class.java]
            }
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                scenario.onActivity { activity ->
                    activity.setContent {
                        CompositionLocalProvider(LocalProfileViewModelFactory provides factory, LocalViewModelStoreOwner provides owner) {
                            HearthRoot(imageLoader = component.imageLoader())
                        }
                    }
                }
                await(hasContentDescription("Filter & Sort"))
                compose.waitUntil(10_000) { library.totalCount.value == fixtures.size }
                block(library, prefs)
            }
        } finally {
            withContext(Dispatchers.Main) { owner.viewModelStore.clear() }
            factory.retire()
            runtimes.close(profileId)
            locations.filesDirectory.deleteRecursively()
            locations.cacheDirectory.deleteRecursively()
            locations.readerDatabaseFile.parentFile!!.deleteRecursively()
        }
    }

    private companion object {
        const val SERIES_ID = "ledger"
        const val COLLAPSED = "Collapsed"
        const val EXPANDED = "Expanded"
        const val AUDIOBOOKS_ONLY = "Audiobooks only"
    }
}
