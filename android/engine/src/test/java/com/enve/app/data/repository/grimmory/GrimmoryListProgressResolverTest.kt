package com.enve.app.data.repository.grimmory

import com.enve.app.data.remote.dto.BookSummaryDto
import com.enve.app.data.remote.dto.GrimmoryAppBookProgressDto
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

class GrimmoryListProgressResolverTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private val epubPercentRow = """{"id":30281,"title":"Enve Namespace Prefix Regression","authors":["Enve Test Lab"],"thumbnailUrl":"/api/books/30281/cover","readStatus":"READING","libraryId":1,"addedOn":"2026-09-20T06:21:53Z","lastReadTime":"2026-09-26T07:30:39Z","readProgress":0.5,"primaryFileId":30285,"primaryFileType":"EPUB","primaryFileName":"Enve Namespace Prefix Regression.epub","isPhysical":false,"categories":[],"tags":[],"moods":[],"language":"en","metadataMatchScore":23.6559,"fileSizeKb":1,"allMetadataLocked":false}"""
    private val epubPercentProgress = """{"readProgress":0.5,"readStatus":"READING","lastReadTime":"2026-09-26T07:30:39Z","epubProgress":{"cfi":"epubcfi(/6/2!/4/2/1:0)","href":null,"percentage":0.5,"updatedAt":"2026-09-26T07:30:39Z"}}"""

    private val koreaderRow = """{"id":1,"title":"Enve Synthetic EPUB","authors":["Enve Test Lab"],"thumbnailUrl":"/api/books/1/cover","readStatus":"READING","libraryId":1,"addedOn":"2026-08-12T04:13:33Z","lastReadTime":"2026-09-14T07:33:05Z","readProgress":0.25,"primaryFileId":1,"primaryFileType":"EPUB","primaryFileName":"Enve Synthetic EPUB.epub","isPhysical":false,"categories":[],"tags":[],"moods":[],"language":"en","publishedDate":"2026-01-01","metadataMatchScore":26.8817,"fileSizeKb":1,"allMetadataLocked":false}"""
    private val koreaderProgress = """{"readProgress":0.25,"readStatus":"READING","lastReadTime":"2026-09-14T07:33:05Z","koreaderProgress":{"percentage":0.25,"device":"Enve Nightly Probe","deviceId":"enve-nightly-probe","lastSyncTime":"2026-09-14T07:33:05Z"}}"""

    private val percentRow = """{"id":30280,"title":"Enve Synthetic EPUB","readStatus":"READING","lastReadTime":"2026-09-20T01:21:15Z","readProgress":68.3333,"primaryFileType":"EPUB"}"""
    private val unreadRow = """{"id":30284,"title":"Unread","primaryFileType":"EPUB"}"""

    private fun row(raw: String) = json.decodeFromString<BookSummaryDto>(raw)
    private fun progress(raw: String) = json.decodeFromString<GrimmoryAppBookProgressDto>(raw)

    @Test
    fun ambiguousRowsResolveFromThePerBookProgressUnits() = runBlocking {
        val rows = listOf(row(epubPercentRow), row(koreaderRow))
        val bodies = mapOf("30281" to progress(epubPercentProgress), "1" to progress(koreaderProgress))

        val fractions = resolveGrimmoryListProgress("conn", rows.map { it.listProgress() }, HashMap()) { bodies[it] }

        assertEquals(0.005f, fractions.getValue("30281"), 0.00001f)
        assertEquals(0.25f, fractions.getValue("1"), 0.00001f)
        assertEquals(0.005f, rows[0].toBook("http://grimmory.test", null, fractions.getValue("30281")).readProgress, 0.00001f)
    }

    @Test
    fun unambiguousRowsNeverFetch() = runBlocking {
        val rows = listOf(row(percentRow), row(unreadRow))
        val fetched = mutableListOf<String>()

        val fractions = resolveGrimmoryListProgress("conn", rows.map { it.listProgress() }, HashMap()) {
            fetched += it
            null
        }

        assertEquals(0.683333f, fractions.getValue("30280"), 0.00001f)
        assertEquals(0f, fractions.getValue("30284"))
        assertTrue(fetched.isEmpty())
    }

    @Test
    fun resolvedUnitsAreCachedPerBookAndLastReadTime() = runBlocking {
        val cache = HashMap<String, Float>()
        val fetched = mutableListOf<String>()
        val fetch: suspend (String) -> GrimmoryAppBookProgressDto? = {
            fetched += it
            progress(koreaderProgress)
        }
        val original = row(koreaderRow).listProgress()

        resolveGrimmoryListProgress("conn", listOf(original), cache, fetch)
        resolveGrimmoryListProgress("conn", listOf(original), cache, fetch)
        assertEquals(listOf("1"), fetched)

        resolveGrimmoryListProgress("conn", listOf(original.copy(lastReadTime = "2026-09-26T08:00:00Z")), cache, fetch)
        resolveGrimmoryListProgress("other", listOf(original), cache, fetch)
        assertEquals(listOf("1", "1", "1"), fetched)
    }

    @Test
    fun failedLookupsAreRetriedInsteadOfGuessed() = runBlocking {
        val cache = HashMap<String, Float>()
        val rows = listOf(row(koreaderRow).listProgress())
        var calls = 0

        val failed = resolveGrimmoryListProgress("conn", rows, cache) {
            calls++
            throw IOException("offline")
        }
        assertEquals(0f, failed.getValue("1"))

        val recovered = resolveGrimmoryListProgress("conn", rows, cache) {
            calls++
            progress(koreaderProgress)
        }
        assertEquals(0.25f, recovered.getValue("1"), 0.00001f)
        assertEquals(2, calls)
    }
}
