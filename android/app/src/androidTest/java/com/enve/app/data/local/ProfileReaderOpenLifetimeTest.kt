package com.enve.app.data.local

import android.app.Activity
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.runner.lifecycle.ActivityLifecycleCallback
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.enve.app.MainActivity
import com.enve.app.profiles.ProfileSwitchCoordinator
import com.enve.core.data.local.FamilyProfileRole
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.ReaderAnnotation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class ProfileReaderOpenLifetimeTest {
    @Test
    fun pendingReaderDetailCannotLaunchOrPersistAfterProfileSwitch() = runBlocking {
        val detailEntered = CountDownLatch(1)
        val releaseDetail = CountDownLatch(1)
        val readerStarts = CopyOnWriteArrayList<String>()
        val lifecycle = ActivityLifecycleMonitorRegistry.getInstance()
        val callback = ActivityLifecycleCallback { activity: Activity, stage: Stage ->
            if (stage == Stage.CREATED && activity.javaClass.simpleName in setOf("EbookReaderActivity", "PdfReaderActivity", "ComicReaderActivity")) {
                readerStarts += activity.javaClass.simpleName
            }
        }
        val server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.requestUrl?.encodedPath) {
                "/api/v2/profiles" -> response("""{"items":[{"id":"reader-fixture","name":"Reader fixture","is_primary":true}]}""")
                "/api/v2/user/libraries" -> response("""{"items":[{"id":"books","name":"Reader fixture","type":"ebook"}]}""")
                "/api/v2/catalog/items/reader-lifetime" -> {
                    detailEntered.countDown()
                    releaseDetail.await(30, TimeUnit.SECONDS)
                    response("""{"content_id":"reader-lifetime","type":"ebook","title":"Delayed reader fixture","original_language":"en","versions":[{"file_id":"epub-file","file_name":"fixture.epub","container":"epub"}]}""")
                }
                "/api/v2/catalog" -> response("""{"items":[],"page":{"has_more":false}}""")
                else -> response("{}").setResponseCode(404)
            }
        }
        server.start()
        lifecycle.addLifecycleCallback(callback)
        try {
            ActivityScenario.launch(MainActivity::class.java).use { scenario ->
                lateinit var profiles: ProfileSwitchCoordinator
                scenario.onActivity { profiles = it.profiles }
                withTimeout(30_000) { profiles.initialize() }
                assumeTrue("Needs an unlocked adult test session", profiles.activeRuntime.value != null && !profiles.state.value.locked &&
                    profiles.state.value.profiles.none { it.role == FamilyProfileRole.CHILD || it.requiresPin })
                val original = profiles.activeRuntime.value!!
                val wasEnabled = profiles.state.value.enabled
                val originalName = profiles.state.value.profiles.single { it.id == original.profileId }.name
                val created = mutableListOf<String>()
                try {
                    if (!wasEnabled) profiles.setupOwner(originalName, null, null)
                    val source = profiles.addProfile("Reader lifetime source", FamilyProfileRole.ADULT)
                    created += source.id
                    val target = profiles.addProfile("Reader lifetime destination", FamilyProfileRole.ADULT)
                    created += target.id
                    profiles.switchProfile(source.id)
                    val runtime = profiles.activeRuntime.value!!
                    val connectionId = UUID.randomUUID().toString()
                    runtime.component.serverSync().setEnabled(false)
                    runtime.component.connections().upsert(ProviderConnection(
                        id = connectionId, source = BookSource.SILO, name = "Reader fixture",
                        serverUrl = server.url("/").toString(), username = "fixture",
                    ))
                    val book = Book(
                        id = "reader-lifetime", title = "Delayed reader fixture", source = BookSource.SILO,
                        mediaType = AppMediaType.EBOOK, hasEbook = true, connectionId = connectionId,
                        libraryId = "$connectionId::books", language = "en",
                    )
                    val hostField = MainActivity::class.java.getDeclaredField("runtimeHost").apply { isAccessible = true }
                    withTimeout(10_000) {
                        var ready = false
                        while (!ready) {
                            scenario.onActivity { activity ->
                                ready = (hostField.get(activity) as? MainActivity.RuntimeHost)?.runtime === runtime
                            }
                            if (!ready) delay(50)
                        }
                    }
                    val openReader = MainActivity::class.java.getDeclaredMethod("openReader", Book::class.java, ReaderAnnotation::class.java)
                        .apply { isAccessible = true }
                    scenario.onActivity { openReader.invoke(it, book, null) }
                    assertTrue("Reader detail request did not start", withContext(Dispatchers.IO) { detailEntered.await(10, TimeUnit.SECONDS) })
                    withTimeout(30_000) { profiles.switchProfile(target.id) }
                    assertEquals(target.id, profiles.activeRuntime.value?.profileId)
                    assertFalse(runtime.component.database().isOpen)
                    releaseDetail.countDown()
                    delay(300)
                    assertTrue("Retired request launched a reader", readerStarts.isEmpty())
                    scenario.onActivity { assertFalse(it.isFinishing) }
                    withTimeout(30_000) { profiles.switchProfile(source.id) }
                    val reopened = profiles.activeRuntime.value!!.component
                    assertNull(reopened.bookCacheDao().getByCacheKey(book.uniqueKey))
                } finally {
                    releaseDetail.countDown()
                    withContext(NonCancellable) {
                        if (profiles.activeRuntime.value?.profileId != original.profileId) profiles.switchProfile(original.profileId)
                        created.asReversed().forEach { profiles.removeProfile(it) }
                        if (!wasEnabled && profiles.state.value.enabled) profiles.disableProfiles()
                    }
                }
            }
        } finally {
            releaseDetail.countDown()
            lifecycle.removeLifecycleCallback(callback)
            server.shutdown()
        }
    }

    private fun response(body: String): MockResponse = MockResponse().setHeader("Content-Type", "application/json").setBody(body)
}
