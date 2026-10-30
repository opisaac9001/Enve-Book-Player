package com.enve.core.data.local

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import com.enve.core.reader.PdfReadingLayout
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File
import java.nio.file.Files

class PdfReadingPreferencesStoreTest {
    @Test
    fun layoutsDefaultOffAndSurviveReopeningTheStore() = runBlocking {
        val directory = Files.createTempDirectory("pdf-layout").toFile()
        val file = directory.resolve("settings.preferences_pb")
        var job = SupervisorJob()
        try {
            var store = PdfReadingPreferencesStore(dataStore(job, file))
            assertEquals(PdfReadingLayout(), store.layout("LOCAL:book-1"))
            store.save("LOCAL:book-1", PdfReadingLayout(twoPageView = true, showCoverSeparately = true, pageAdjust = "FillHeight"))
            store.save("LOCAL:book-2", PdfReadingLayout(twoPageView = true, pageAdjust = "FillWidth"))
            job.cancelAndJoin()

            job = SupervisorJob()
            store = PdfReadingPreferencesStore(dataStore(job, file))
            assertEquals(PdfReadingLayout(twoPageView = true, showCoverSeparately = true, pageAdjust = "FillHeight"), store.layout("LOCAL:book-1"))
            assertEquals(PdfReadingLayout(twoPageView = true, pageAdjust = "FillWidth"), store.layout("LOCAL:book-2"))
            assertEquals(PdfReadingLayout(), store.layout("LOCAL:book-3"))
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    @Test
    fun layoutsAreKeyedPerBookAndConnection() = runBlocking {
        val directory = Files.createTempDirectory("pdf-layout-keys").toFile()
        val job = SupervisorJob()
        try {
            val store = PdfReadingPreferencesStore(dataStore(job, directory.resolve("settings.preferences_pb")))
            store.save("connection-a:book", PdfReadingLayout(twoPageView = true))
            assertEquals(PdfReadingLayout(twoPageView = true), store.layout("connection-a:book"))
            assertEquals(PdfReadingLayout(), store.layout("connection-b:book"))
            assertEquals(PdfReadingLayout(), store.layout("KOMGA:book"))
            assertEquals(PdfReadingLayout(), store.layout("connection-a:book-2"))

            store.save("connection-a:book", PdfReadingLayout(twoPageView = true, showCoverSeparately = true, pageAdjust = "FillHeight"))
            store.save("connection-a:book", PdfReadingLayout(twoPageView = false, showCoverSeparately = true, pageAdjust = "FillHeight"))
            assertEquals(PdfReadingLayout(twoPageView = false, showCoverSeparately = true, pageAdjust = "FillHeight"), store.layout("connection-a:book"))

            store.clear("connection-a:book")
            assertEquals(PdfReadingLayout(), store.layout("connection-a:book"))
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    @Test
    fun profilesWithSeparatePreferenceFilesDoNotShareLayouts() = runBlocking {
        val directory = Files.createTempDirectory("pdf-layout-profiles").toFile()
        val job = SupervisorJob()
        try {
            val adult = PdfReadingPreferencesStore(dataStore(job, directory.resolve("adult.preferences_pb")))
            val child = PdfReadingPreferencesStore(dataStore(job, directory.resolve("child.preferences_pb")))
            adult.save("LOCAL:shared-book", PdfReadingLayout(twoPageView = true, showCoverSeparately = true, pageAdjust = "FillHeight"))
            assertEquals(PdfReadingLayout(twoPageView = true, showCoverSeparately = true, pageAdjust = "FillHeight"), adult.layout("LOCAL:shared-book"))
            assertEquals(PdfReadingLayout(), child.layout("LOCAL:shared-book"))
            child.save("LOCAL:shared-book", PdfReadingLayout(twoPageView = true, pageAdjust = "FillWidth"))
            assertEquals(PdfReadingLayout(twoPageView = true, showCoverSeparately = true, pageAdjust = "FillHeight"), adult.layout("LOCAL:shared-book"))
            assertEquals(PdfReadingLayout(twoPageView = true, pageAdjust = "FillWidth"), child.layout("LOCAL:shared-book"))
        } finally {
            job.cancelAndJoin()
            directory.deleteRecursively()
        }
    }

    private fun dataStore(job: kotlinx.coroutines.Job, file: File) =
        PreferenceDataStoreFactory.create(scope = CoroutineScope(job + Dispatchers.IO)) { file }
}
