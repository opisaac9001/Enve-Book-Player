package com.enve.app.hearth

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.file.Files

class HearthLibraryPreferencesTest {
    @Test
    fun librarySelectionMediaAndComicBrowsingStayInTheirScopeAndProfile() = runBlocking {
        val directory = Files.createTempDirectory("hearth-library").toFile()
        var job = SupervisorJob()
        try {
            fun open(name: String) = HearthPreferencesStore(
                PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) {
                    directory.resolve("$name.preferences_pb")
                },
            )
            var adult = open("adult")
            val child = open("child")
            adult.setLibraryMedia("AUDIOBOOKS")
            adult.setScopedLibraryMedia("library:komga::comics", "ALL")
            adult.setScopedLibraryMedia("source:KOMGA", "COMICS")
            adult.setComicBrowseState("library:komga::comics", """{"facet":"BOOKS"}""")
            adult.setLibrarySelection("""{"source":"KOMGA","libraryId":"komga::comics","connectionId":"komga"}""")

            assertEquals("AUDIOBOOKS", adult.libraryMedia.first())
            assertEquals("", adult.scopedLibraryMedia("library:komga::other").first())
            assertEquals("", adult.comicBrowseState("source:KOMGA").first())
            assertEquals("", child.librarySelection.first())
            assertEquals("", child.scopedLibraryMedia("library:komga::comics").first())
            job.cancelAndJoin()

            job = SupervisorJob()
            adult = open("adult")
            assertEquals("AUDIOBOOKS", adult.libraryMedia.first())
            assertEquals("ALL", adult.scopedLibraryMedia("library:komga::comics").first())
            assertEquals("COMICS", adult.scopedLibraryMedia("source:KOMGA").first())
            assertEquals("""{"facet":"BOOKS"}""", adult.comicBrowseState("library:komga::comics").first())
            assertEquals(
                """{"source":"KOMGA","libraryId":"komga::comics","connectionId":"komga"}""",
                adult.librarySelection.first(),
            )
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }
}
