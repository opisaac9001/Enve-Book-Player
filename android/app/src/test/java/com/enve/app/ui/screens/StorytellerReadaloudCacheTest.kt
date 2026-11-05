package com.enve.app.ui.screens

import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okio.Buffer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class StorytellerReadaloudCacheTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun regeneratedArchiveReplacesTheOldAudioAndUnchangedArchiveIsNotDownloaded() = runBlocking {
        MockWebServer().use { server ->
            val file = temporary.newFile("book.epub").apply { writeBytes(epub("old.opus")) }
            StorytellerReadaloudCache.recordRevision(file, "old", null)
            val replacement = epub("new.mp3")
            server.enqueue(MockResponse().setResponseCode(206).setHeader("ETag", "new").setBody("P"))
            server.enqueue(MockResponse().setHeader("ETag", "new").setBody(Buffer().write(replacement)))
            StorytellerReadaloudCache.refresh(file, server.url("/files?format=readaloud").toString(), OkHttpClient())
            assertArrayEquals(replacement, file.readBytes())
            assertEquals("bytes=0-0", server.takeRequest().getHeader("Range"))
            assertNull(server.takeRequest().getHeader("Range"))
            server.enqueue(MockResponse().setResponseCode(206).setHeader("ETag", "new").setBody("P"))
            StorytellerReadaloudCache.refresh(file, server.url("/files").toString(), OkHttpClient())
            assertEquals(3, server.requestCount)
        }
    }

    @Test fun legacyCopyIsRefreshedAndFailedOrInvalidReplacementsPreserveIt() = runBlocking {
        MockWebServer().use { server ->
            val original = epub("old.opus")
            val file = temporary.newFile("legacy.epub").apply { writeBytes(original) }
            for (body in listOf("server error", "not an epub")) {
                server.enqueue(MockResponse().setResponseCode(206).setHeader("ETag", "changed").setBody("P"))
                server.enqueue(MockResponse().setResponseCode(if (body == "server error") 500 else 200).setBody(body))
                StorytellerReadaloudCache.refresh(file, server.url("/files").toString(), OkHttpClient())
                assertArrayEquals(original, file.readBytes())
                assertFalse(java.io.File(file.parentFile, ".${file.name}.revision").exists())
            }
            server.enqueue(MockResponse().setResponseCode(401))
            StorytellerReadaloudCache.refresh(file, server.url("/files").toString(), OkHttpClient())
            assertArrayEquals(original, file.readBytes())
            val updated = epub("replacement.mp3")
            server.enqueue(MockResponse().setResponseCode(206).setHeader("ETag", "changed").setBody("P"))
            server.enqueue(MockResponse().setHeader("ETag", "changed").setBody(Buffer().write(updated)))
            StorytellerReadaloudCache.refresh(file, server.url("/files").toString(), OkHttpClient())
            assertArrayEquals(updated, file.readBytes())
            assertTrue(temporary.root.listFiles()!!.none { it.name.endsWith(".part") })
        }
    }

    private fun epub(audio: String): ByteArray = ByteArrayOutputStream().also { bytes ->
        ZipOutputStream(bytes).use { zip ->
            zip.putNextEntry(ZipEntry("META-INF/container.xml"))
            zip.write("<container/>".toByteArray())
            zip.closeEntry()
            zip.putNextEntry(ZipEntry(audio))
            zip.write(audio.toByteArray())
            zip.closeEntry()
        }
    }.toByteArray()
}
