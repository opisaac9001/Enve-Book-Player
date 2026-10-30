package com.enve.app.listeningposition

import android.graphics.Bitmap
import android.view.TextureView
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.matcher.ViewMatchers.isAssignableFrom
import androidx.test.espresso.NoMatchingViewException
import android.Manifest
import android.content.Context
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraCharacteristics
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.mutableStateOf
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assume.assumeTrue
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import com.enve.core.listeningposition.SharedReadingLocation
import com.enve.core.data.model.BookSource
import com.enve.core.listeningposition.ListeningPositionPayload
import com.enve.engine.listeningposition.*
import com.enve.engine.theme.HearthThemeMode
import com.enve.hearth.design.HearthTheme
import com.enve.hearth.listeningposition.*
import com.enve.hearth.shell.LocalProfileViewModelFactory
import java.io.ByteArrayOutputStream
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ListeningPositionUiTest {
    @get:Rule val compose = createComposeRule()
    private val book = Book("fixture", "The Shared Book", author = "Enve Test", duration = 3600, currentTime = 300,
        source = BookSource.LOCAL, connectionId = "one")
    private val payload = ListeningPositionPayload(90000, 3600000, book.title, listOf("Enve Test"))
    private val candidate = ListeningPositionCandidate(book, 1.0, true, emptyList(), true, "My Library · My account")
    private var suggestedCandidate = candidate
    private val applied = mutableListOf<String>()
    private var searches = mutableListOf<String>()
    private val facade = object : ListeningPositionFacade {
        override fun share(book: Book) = ListeningPositionPayload.from(book)
        override suspend fun suggestions(payload: ListeningPositionPayload) = listOf(suggestedCandidate)
        override suspend fun search(payload: ListeningPositionPayload, query: String): List<ListeningPositionCandidate> {
            searches += query
            return listOf(candidate.copy(book = book.copy(id = "manual"), hasCredibleIdentity = false, warnings = listOf("Different narrator.")))
        }
        override suspend fun apply(payload: ListeningPositionPayload, book: Book): ListeningPositionApplyResult {
            applied += book.uniqueKey
            val location = payload.readingLocation
            val updated = if (location != null) book.copy(epubProgress = location.progressionFor(book), readProgress = location.progressionFor(book), epubLocator = location.locatorFor(book))
                else book.copy(currentTime = payload.positionMilliseconds / 1000)
            return ListeningPositionApplyResult(updated, payload.positionMilliseconds, ListeningPositionServerStatus.NO_SERVER, location)
        }
    }
    private lateinit var model: ListeningPositionViewModel
    private val factory = object : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = ListeningPositionViewModel(facade).also { model = it } as T
    }

    @Test fun selectionAndConfirmationAreRequiredBeforeMovingProgress() {
        compose.setContent { CompositionLocalProvider(LocalProfileViewModelFactory provides factory) { HearthTheme { ListeningPositionScanScreen {} } } }
        compose.runOnIdle { model.scan(payload.encoded()) }
        compose.waitUntil(5000) { compose.onAllNodesWithTag("listening-position-candidate-one:fixture").fetchSemanticsNodes().isNotEmpty() }
        assertTrue(applied.isEmpty())
        evidence("enve-position-matches.png")
        compose.onNodeWithTag("listening-position-candidate-one:fixture").performScrollTo().performClick()
        assertTrue(applied.isEmpty())
        compose.onNodeWithTag("listening-position-apply").performScrollTo().assertIsDisplayed()
        evidence("enve-position-confirmation.png")
        compose.onNodeWithTag("listening-position-apply").performClick()
        compose.onNodeWithTag("listening-position-done").performScrollTo().assertIsDisplayed()
        assertEquals(listOf(book.uniqueKey), applied)
        compose.onNodeWithText("This copy isn't connected to a progress server.", substring = true).assertExists()
        evidence("enve-position-saved.png")
    }

    @Test fun readingPositionUsesPercentageAndRequiresConfirmation() {
        val readingBook = book.copy(mediaType = AppMediaType.EBOOK, primaryFileType = "EPUB", epubProgress = 0.8f)
        suggestedCandidate = candidate.copy(book = readingBook)
        val reading = ListeningPositionPayload(0, 0, book.title, listOf("Enve Test"), readingLocation = SharedReadingLocation("epub", 250000))
        compose.setContent { CompositionLocalProvider(LocalProfileViewModelFactory provides factory) { HearthTheme { ListeningPositionScanScreen {} } } }
        compose.runOnIdle { model.scan(reading.encoded()) }
        compose.waitUntil(5000) { compose.onAllNodesWithTag("listening-position-candidate-one:fixture").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("25.0%").assertExists()
        assertTrue(applied.isEmpty())
        compose.onNodeWithTag("listening-position-candidate-one:fixture").performScrollTo().performClick()
        compose.onNodeWithText("Shared: 25.0%").assertExists()
        compose.onNodeWithText("Now: 80.0%").assertExists()
        compose.onNodeWithText("Move to 25.0%").performScrollTo().assertIsDisplayed()
        assertTrue(applied.isEmpty())
        compose.onNodeWithTag("listening-position-apply").performClick()
        compose.onNodeWithText("Moved to 25.0%.", substring = true).performScrollTo().assertExists()
        assertEquals(listOf(book.uniqueKey), applied)
    }

    @Test fun manualLibrarySearchCanSelectAnEditionOutsideSuggestions() {
        compose.setContent { CompositionLocalProvider(LocalProfileViewModelFactory provides factory) { HearthTheme(mode = HearthThemeMode.INK) { ListeningPositionScanScreen {} } } }
        compose.runOnIdle { model.scan(payload.encoded()) }
        compose.onNodeWithTag("listening-position-search").performScrollTo().performTextInput("Other edition")
        compose.waitUntil(5000) { compose.onAllNodesWithTag("listening-position-candidate-one:manual").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithTag("listening-position-candidate-one:manual").performScrollTo().performClick()
        compose.onNodeWithText("Different narrator.").assertExists()
        assertTrue(applied.isEmpty())
        evidence("enve-position-dark.png")
        compose.onNodeWithTag("listening-position-apply").performScrollTo().performClick()
        assertEquals(listOf("one:manual"), applied)
        assertTrue(searches.contains("Other edition"))
    }

    @Test fun sharedCodeIsAvailableAtLargeTextSizes() {
        compose.setContent { CompositionLocalProvider(LocalProfileViewModelFactory provides factory) { HearthTheme(uiTextScale = 1.7f) { ListeningPositionShareSheet(book) {} } } }
        compose.waitUntil(5000) { compose.onAllNodesWithTag("listening-position-qr").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("Share image").performScrollTo().assertIsDisplayed()
        evidence("enve-position-share-large-text.png")
    }


    @Test fun emulatorCameraClosesWhenTheScannerLeavesComposition() {
        assumeTrue(Build.MODEL.startsWith("sdk_gphone") && Build.VERSION.SDK_INT >= 29)
        val context = ApplicationProvider.getApplicationContext<Context>()
        val manager = context.getSystemService(CameraManager::class.java)
        val id = manager.cameraIdList.firstOrNull {
            manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        }
        assumeTrue(id != null)
        InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.CAMERA)
        val opened = AtomicBoolean(false)
        val released = AtomicBoolean(false)
        val callback = object : CameraManager.AvailabilityCallback() {
            override fun onCameraUnavailable(cameraId: String) { if (cameraId == id) opened.set(true) }
            override fun onCameraAvailable(cameraId: String) { if (cameraId == id && opened.get()) released.set(true) }
        }
        val visible = mutableStateOf(true)
        manager.registerAvailabilityCallback(callback, Handler(Looper.getMainLooper()))
        try {
            compose.setContent {
                CompositionLocalProvider(LocalProfileViewModelFactory provides factory) {
                    HearthTheme { if (visible.value) ListeningPositionScanScreen {} }
                }
            }
            compose.waitUntil(10000) { opened.get() }
            compose.onNodeWithText("Camera scanning isn't available", substring = true).assertDoesNotExist()
            var frame: Bitmap? = null
            compose.waitUntil(10000) {
                try {
                    onView(isAssignableFrom(TextureView::class.java)).check { view, _ ->
                        val image = (view as TextureView).bitmap
                        if (image != null) {
                            val colors = (0 until 16).flatMap { y -> (0 until 16).map { x -> image.getPixel(x * (image.width - 1) / 15, y * (image.height - 1) / 15) } }.distinct()
                            if (colors.size > 4) frame = image else image.recycle()
                        }
                    }
                } catch (_: NoMatchingViewException) { }
                frame != null
            }
            val bytes = ByteArrayOutputStream().also { frame!!.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
            savePositionEvidence("enve-position-camera-frame.png", bytes)
            frame!!.recycle()
            evidence("enve-position-camera.png")
            compose.runOnIdle { visible.value = false }
            compose.waitUntil(10000) { released.get() }
        } finally { manager.unregisterAvailabilityCallback(callback) }
    }

    private fun evidence(name: String) {
        val bitmap = compose.onNodeWithTag("listening-position-screen").captureToImage().asAndroidBitmap()
        val bytes = ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
        savePositionEvidence(name, bytes)
    }
}
