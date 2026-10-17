package com.enve.app.viewmodel

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.ui.screens.readComicArchiveDirection
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ComicArchiveMetadataTest {
    @Test
    fun readsComicInfoInsideNestedCbzPaths() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val archive = File.createTempFile("comic-info-", ".cbz", context.cacheDir)
        try {
            ZipOutputStream(archive.outputStream()).use { zip ->
                zip.putNextEntry(ZipEntry("metadata/ComicInfo.xml"))
                zip.write("<ComicInfo><Manga>YesAndRightToLeft</Manga></ComicInfo>".toByteArray())
                zip.closeEntry()
            }
            assertEquals(ComicReadingDirection.RIGHT_TO_LEFT, readComicArchiveDirection(archive))
        } finally {
            archive.delete()
        }
    }

    @Test
    fun readsComicInfoFromARarArchive() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val archive = File.createTempFile("comic-info-", ".cbr", context.cacheDir)
        try {
            InstrumentationRegistry.getInstrumentation().context.assets.open("comics/rtl.cbr").use { input ->
                archive.outputStream().use { input.copyTo(it) }
            }
            assertEquals(ComicReadingDirection.RIGHT_TO_LEFT, readComicArchiveDirection(archive))
        } finally {
            archive.delete()
        }
    }

    @Test
    fun malformedArchivesDoNotInventADirection() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val archive = File.createTempFile("comic-info-", ".cbz", context.cacheDir)
        try {
            archive.writeText("not an archive")
            assertNull(readComicArchiveDirection(archive))
        } finally {
            archive.delete()
        }
    }
}
