package com.enve.app.data.local

import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.WorkManager
import com.enve.app.data.offline.OfflineAudioManifest
import com.enve.app.data.offline.OfflineAudioTrackManifest
import com.enve.app.profiles.ProfileDeviceAuthentication
import com.enve.app.profiles.ProfileLifecycleRegistry
import com.enve.app.profiles.ProfileRuntimeRegistry
import com.enve.app.profiles.ProfileSwitchCoordinator
import com.enve.core.data.local.FamilyProfileStore
import com.enve.core.data.local.BookExtras
import com.enve.core.data.local.decodeChapters
import com.enve.core.data.local.encodeChaptersJson
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.engine.profiles.ProfileDownloadFormat
import java.io.File
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ProfileSwitchLifetimeTest {
    @Test
    fun audioImportPreservesPrivateChapterMetadataAcrossReopenAndRepeatImport() = runBlocking {
        val base = ApplicationProvider.getApplicationContext<Context>()
        WorkManager.getInstance(base)
        val context = SwitchTestContext(base)
        val applicationJob = SupervisorJob()
        val applicationScope = CoroutineScope(applicationJob + Dispatchers.Default)
        val catalog = FamilyProfileStore(context)
        val sourceProfile = catalog.addAdult("Source test profile")
        val targetProfile = catalog.addAdult("Target test profile")
        context.getSharedPreferences("family_profile_runtime", Context.MODE_PRIVATE).edit()
            .putBoolean("enabled", true).putString("selected", sourceProfile.id).commit()
        val runtimes = ProfileRuntimeRegistry(context)
        val coordinator = ProfileSwitchCoordinator(
            context, catalog, runtimes, ProfileLifecycleRegistry(), ProfileDeviceAuthentication(context), applicationScope,
        )
        try {
            val source = runtimes.open(sourceProfile.id)
            val sourceBook = Book(
                id = "chapter-audio", title = "Chapter audio", source = BookSource.GRIMMORY,
                connectionId = "source-account", mediaType = AppMediaType.AUDIOBOOK,
                currentTime = 35L, isFinished = true, duration = 60L,
            )
            val chapters = listOf("Opening", "Middle", "Ending").mapIndexed { index, title ->
                Chapter(index = index, title = title, startTime = index * 20L, endTime = (index + 1) * 20L)
            }
            source.bookCacheDao().insertIfAbsent(sourceBook.toCachedBook())
            source.database().bookExtrasDao().upsert(
                BookExtras(sourceBook.uniqueKey, encodeChaptersJson(chapters), "[{\"contentUrl\":\"https://example.invalid/audio?token=test-secret\"}]"),
            )
            val storage = source.audioStorage()
            val payload = storage.createTrackFinalFile(sourceBook.id, 0, "mp3").also { it.writeText("audio bytes") }
            storage.saveManifest(
                OfflineAudioManifest(
                    sourceBook.id, sourceBook.title, source = sourceBook.source.name, downloadedAtEpochMs = 1L,
                    tracks = listOf(OfflineAudioTrackManifest(0, "Single file", 60_000L, storage.relativePath(payload), payload.length())),
                ),
            )
            val imported = coordinator.importCompleted(
                sourceProfile.id, targetProfile.id, "AUDIOBOOK:${sourceBook.id}", ProfileDownloadFormat.AUDIOBOOK,
            )
            assertEquals(BookSource.LOCAL, imported.source)
            assertNull(imported.connectionId)
            assertEquals(0L, imported.currentTime)
            assertFalse(imported.isFinished)
            var target = runtimes.open(targetProfile.id)
            val extras = target.database().bookExtrasDao().get(imported.uniqueKey)!!
            assertEquals(chapters, extras.decodeChapters())
            assertEquals("[]", extras.audioTracksJson)
            assertEquals(chapters, target.library().chapters(imported, forceEmbedded = false))
            assertEquals(payload.canonicalFile, target.audioStorage().absolutePath(target.audioStorage().getManifest(imported.id)!!.tracks.single().relativePath))
            runtimes.close(targetProfile.id)
            target = runtimes.open(targetProfile.id)
            assertEquals(chapters, target.database().bookExtrasDao().get(imported.uniqueKey)!!.decodeChapters())
            val editedChapters = chapters.map { it.copy(title = "Local ${it.title}") }
            target.database().bookExtrasDao().upsert(extras.copy(chaptersJson = encodeChaptersJson(editedChapters)))
            val repeated = coordinator.importCompleted(
                sourceProfile.id, targetProfile.id, "AUDIOBOOK:${sourceBook.id}", ProfileDownloadFormat.AUDIOBOOK,
            )
            assertEquals(imported.id, repeated.id)
            assertEquals(editedChapters, target.database().bookExtrasDao().get(imported.uniqueKey)!!.decodeChapters())
        } finally {
            withContext(NonCancellable) {
                applicationJob.cancelAndJoin()
                runtimes.close(sourceProfile.id)
                runtimes.close(targetProfile.id)
            }
            context.clear()
        }
    }

    @Test
    fun disposingInitiatingScreenDoesNotCancelSwitchDuringCheckpoint() = runBlocking {
        val base = ApplicationProvider.getApplicationContext<Context>()
        WorkManager.getInstance(base)
        val context = SwitchTestContext(base)
        val applicationJob = SupervisorJob()
        val applicationScope = CoroutineScope(applicationJob + Dispatchers.Default)
        val catalog = FamilyProfileStore(context)
        val outgoing = catalog.addAdult("Outgoing test profile")
        val destination = catalog.addAdult("Destination test profile")
        context.getSharedPreferences("family_profile_runtime", Context.MODE_PRIVATE).edit()
            .putBoolean("enabled", true).putString("selected", outgoing.id).commit()
        val runtimes = ProfileRuntimeRegistry(context)
        val lifecycle = ProfileLifecycleRegistry()
        val coordinator = ProfileSwitchCoordinator(
            context, catalog, runtimes, lifecycle, ProfileDeviceAuthentication(context), applicationScope,
        )
        val entered = CompletableDeferred<Unit>()
        val finishCheckpoint = CompletableDeferred<Unit>()
        val registration = lifecycle.register(outgoing.id) {
            entered.complete(Unit)
            finishCheckpoint.await()
        }
        try {
            awaitStage("initialization", coordinator) { coordinator.initialize() }
            val screen = launch { coordinator.switchProfile(destination.id) }
            awaitStage("outgoing checkpoint", coordinator) { entered.await() }
            assertTrue(coordinator.state.value.switching)
            screen.cancelAndJoin()
            finishCheckpoint.complete(Unit)
            awaitStage("destination publication", coordinator) {
                coordinator.activeRuntime.first { it?.profileId == destination.id }
                coordinator.state.first { !it.switching }
            }
            assertFalse(coordinator.state.value.locked)
        } finally {
            finishCheckpoint.complete(Unit)
            registration.close()
            withContext(NonCancellable) {
                applicationJob.cancelAndJoin()
                runtimes.close(outgoing.id)
                runtimes.close(destination.id)
            }
            context.clear()
        }
    }

    private suspend fun awaitStage(
        stage: String,
        coordinator: ProfileSwitchCoordinator,
        block: suspend () -> Unit,
    ) {
        try {
            withTimeout(30_000L) { block() }
        } catch (error: TimeoutCancellationException) {
            val state = coordinator.state.value
            throw AssertionError(
                "Timed out during $stage: enabled=${state.enabled}, switching=${state.switching}, " +
                    "locked=${state.locked}, runtimePresent=${coordinator.activeRuntime.value != null}, " +
                    "errorPresent=${state.error != null}",
                error,
            )
        }
    }

    private class SwitchTestContext(base: Context) : ContextWrapper(base) {
        private val prefix = "switch-lifetime-${UUID.randomUUID()}-"
        private val root = File(base.cacheDir, prefix).also { check(it.mkdirs()) }
        private val preferences = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()

        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = File(root, "files").also { it.mkdirs(); check(it.isDirectory) }
        override fun getCacheDir(): File = File(root, "cache").also { it.mkdirs(); check(it.isDirectory) }
        override fun getDatabasePath(name: String): File = File(root, "databases/$name").also {
            val parent = checkNotNull(it.parentFile)
            parent.mkdirs()
            check(parent.isDirectory)
        }
        override fun getSharedPreferences(name: String, mode: Int) =
            baseContext.getSharedPreferences(prefix + name, mode).also { preferences += prefix + name }

        fun clear() {
            preferences.forEach(baseContext::deleteSharedPreferences)
            root.deleteRecursively()
        }
    }
}
