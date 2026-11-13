package com.enve.app.ui.screens

import android.content.Context
import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.lifecycle.ViewModelStore
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.MainActivity
import com.enve.app.hearth.HearthPreferencesStore
import com.enve.app.profiles.ProfileActivityBinding
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.model.ProviderConnection
import com.enve.engine.library.LibraryFacade
import com.enve.engine.prefs.PreferencesFacade
import com.enve.hearth.library.HearthLibraryViewModel
import com.enve.hearth.library.LibrarySelection
import com.enve.hearth.library.MediaFilter
import dagger.hilt.android.EntryPointAccessors
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryPersistenceTest {
    @Test
    fun savedAudioFiltersSurviveRecreationAndStaggeredOfflineCatalogs() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val profiles = EntryPointAccessors.fromApplication(context, ProfileActivityBinding.DeviceEntryPoint::class.java).profiles()
        ActivityScenario.launch(MainActivity::class.java).use {
            withTimeout(20_000) { profiles.activeRuntime.first { it != null } }
        }
        val component = checkNotNull(profiles.activeRuntime.value).component
        val directory = File(context.cacheDir, "library-persistence-${UUID.randomUUID()}").also { it.mkdirs() }
        val job = SupervisorJob()
        val scope = CoroutineScope(job + Dispatchers.IO)
        val registry = ConnectionRegistry(PreferenceDataStoreFactory.create(scope = scope) { File(directory, "connections.preferences_pb") })
        val store = HearthPreferencesStore(PreferenceDataStoreFactory.create(scope = scope) { File(directory, "filters.preferences_pb") })
        val prefs = object : PreferencesFacade by component.preferencesFacade() {
            override val librarySelection = store.librarySelection
            override val libraryMedia = store.libraryMedia
            override val readingEnabled = flowOf(true)
            override val excludedLibraryIds = flowOf(emptySet<String>())
            override fun scopedLibraryMedia(scope: String) = store.scopedLibraryMedia(scope)
            override suspend fun setLibrarySelection(encoded: String) = store.setLibrarySelection(encoded)
            override suspend fun setLibraryMedia(encoded: String) = store.setLibraryMedia(encoded)
            override suspend fun setScopedLibraryMedia(scope: String, encoded: String) = store.setScopedLibraryMedia(scope, encoded)
        }
        val catalog = MutableStateFlow(emptyList<Book>())
        val libraries = MutableStateFlow(emptyList<Library>())
        val library = object : LibraryFacade by component.library() {
            override val allBooks = catalog
            override val libraries = libraries
        }
        val abs = ProviderConnection("audio", BookSource.AUDIOBOOKSHELF, "Audio", "https://audio.invalid", "test")
        val other = ProviderConnection("other", BookSource.KOMGA, "Other", "https://other.invalid", "test")
        val audioLibrary = Library("audio::books", "Books", source = abs.source, connectionId = abs.id)
        val otherLibrary = Library("other::comics", "Comics", source = other.source, connectionId = other.id)
        val scopes = listOf(LibrarySelection(), LibrarySelection(abs.source), LibrarySelection(abs.source, audioLibrary.id, abs.id))
        val models = mutableListOf<ViewModelStore>()
        suspend fun open(): HearthLibraryViewModel = withContext(Dispatchers.Main) {
            HearthLibraryViewModel(library, component.savedBooks(), component.playback(), prefs, registry).also {
                val owner = ViewModelStore()
                owner.put("library", it)
                models += owner
            }
        }
        suspend fun awaitState(vm: HearthLibraryViewModel, selection: LibrarySelection, phase: String) {
            try {
                withTimeout(5_000) {
                    vm.librarySelection.first { it == selection }
                    vm.effectiveMedia.first { it == MediaFilter.AUDIOBOOKS }
                }
            } catch (error: TimeoutCancellationException) {
                throw AssertionError("$phase: expected $selection/AUDIOBOOKS, actual ${vm.librarySelection.value}/${vm.effectiveMedia.value}, saved=${prefs.librarySelection.first()}", error)
            }
        }
        suspend fun awaitSaved(selection: LibrarySelection, phase: String, block: suspend () -> Unit) {
            try {
                withTimeout(5_000) { block() }
            } catch (error: TimeoutCancellationException) {
                throw AssertionError("$phase: expected $selection, saved=${prefs.librarySelection.first()}, all=${prefs.libraryMedia.first()}, source=${prefs.scopedLibraryMedia("source:AUDIOBOOKSHELF").first()}, library=${prefs.scopedLibraryMedia("library:${audioLibrary.id}").first()}", error)
            }
        }
        try {
            registry.upsert(abs)
            registry.upsert(other)
            for (selection in scopes) {
                libraries.value = listOf(audioLibrary, otherLibrary)
                val vm = open()
                awaitSaved(selection, "initial catalog") { vm.libraries.first { list -> list.any { it.id == audioLibrary.id } } }
                withContext(Dispatchers.Main) {
                    vm.setSourceFilter(selection.source)
                    vm.setLibraryFilter(selection.libraryId)
                    vm.setMedia(MediaFilter.AUDIOBOOKS)
                }
                awaitState(vm, selection, "selected")
                awaitSaved(selection, "persisted selection") { prefs.librarySelection.first { runCatching { Json.decodeFromString<LibrarySelection>(it) }.getOrNull() == selection } }
                val mediaKey = selection.libraryId?.let { "library:$it" } ?: selection.source?.let { "source:${it.name}" }
                awaitSaved(selection, "persisted media") {
                    (mediaKey?.let(prefs::scopedLibraryMedia) ?: prefs.libraryMedia).first { it == "AUDIOBOOKS" }
                }
                withContext(Dispatchers.Main) { models.last().clear() }
                libraries.value = emptyList()
                val reopened = open()
                awaitState(reopened, selection, "reopened catalogs=${libraries.value.map { it.id }}")
                libraries.value = listOf(otherLibrary)
                awaitState(reopened, selection, "reopened catalogs=${libraries.value.map { it.id }}")
                libraries.value = listOf(otherLibrary, audioLibrary)
                awaitState(reopened, selection, "reopened catalogs=${libraries.value.map { it.id }}")
                libraries.value = emptyList()
                awaitState(reopened, selection, "reopened catalogs=${libraries.value.map { it.id }}")
                assertEquals(MediaFilter.AUDIOBOOKS, reopened.effectiveMedia.value)
                withContext(Dispatchers.Main) { models.last().clear() }
            }
        } finally {
            withContext(Dispatchers.Main) { models.forEach { it.clear() } }
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }
}
