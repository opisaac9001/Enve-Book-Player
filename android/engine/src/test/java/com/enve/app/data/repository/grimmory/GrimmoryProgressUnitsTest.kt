package com.enve.app.data.repository.grimmory

import com.enve.app.data.remote.dto.BookDetailDto
import com.enve.app.data.remote.dto.GrimmoryAppBookProgressDto
import com.enve.app.data.repository.grimmoryOidcUsername
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GrimmoryProgressUnitsTest {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    @Test
    fun detailFormatPercentagesAreHundredBasedAndKoreaderIsAFraction() {
        val detail = json.decodeFromString<BookDetailDto>(
            """{"id":30280,"title":"Enve Synthetic EPUB","authors":["Enve Test Lab"],"libraryId":3,"libraryName":"Enve Audiobooks","readStatus":"READING","readProgress":0.683333,"primaryFileType":"EPUB","fileTypes":["AUDIOBOOK","EPUB"],"epubProgress":{"cfi":"epubcfi(/6/2!/4,/2,/6/1:58)","href":"EPUB/chapter.xhtml","percentage":68.3333,"updatedAt":"2026-09-20T01:21:15Z"},"audiobookProgress":{"positionMs":41000,"trackIndex":null,"percentage":68.3333,"updatedAt":"2026-09-20T01:21:14Z"},"koreaderProgress":{"percentage":0.683333,"device":null,"deviceId":null,"lastSyncTime":"2026-09-20T01:21:15Z"},"lastReadTime":"2026-09-20T01:21:15Z","addedOn":"2026-09-19T21:46:41Z"}"""
        )

        val book = detail.toBook("http://grimmory.test")

        assertEquals(0.6833f, book.readProgress, 0.0001f)
        assertEquals(0.6833f, book.epubProgress!!, 0.0001f)
        assertEquals(41L, book.currentTime)
        assertFalse(book.isFinished)
    }

    @Test
    fun readProgressWithoutKoreaderIsAPercent() {
        val detail = json.decodeFromString<BookDetailDto>(
            """{"id":7,"title":"Kobo only","readStatus":"READING","readProgress":0.5,"primaryFileType":"EPUB"}"""
        )

        val book = detail.toBook("http://grimmory.test")

        assertEquals(0.005f, book.readProgress, 0.0001f)
        assertFalse(book.isFinished)
    }

    @Test
    fun progressEndpointSnapshotsUseExactUnits() {
        val body = json.decodeFromString<GrimmoryAppBookProgressDto>(
            """{"readProgress":0.35,"readStatus":"READING","lastReadTime":"2026-09-19T22:28:25Z","epubProgress":{"cfi":"epubcfi(/6/2!/4,/2,/6/1:58)","href":null,"percentage":100.0,"updatedAt":"2026-09-19T22:28:25Z"},"audiobookProgress":{"positionMs":21000,"trackIndex":null,"percentage":35.0,"updatedAt":"2026-09-19T22:28:25Z"},"koreaderProgress":{"percentage":0.35,"device":null,"deviceId":null,"lastSyncTime":"2026-09-19T22:28:25Z"}}"""
        )

        assertEquals(0.35f, grimmoryAudiobookProgressSnapshot(body, null)!!.percentage, 0.0001f)
        assertEquals(1f, grimmoryEbookProgressSnapshot(body, null)!!.percentage, 0.0001f)
    }

    @Test
    fun koreaderOnlyProgressFinishesTheBook() {
        val body = json.decodeFromString<GrimmoryAppBookProgressDto>(
            """{"readProgress":1.0,"readStatus":"READ","lastReadTime":"2026-09-14T16:14:24Z","koreaderProgress":{"percentage":1.0,"device":null,"deviceId":null,"lastSyncTime":"2026-09-14T16:14:24Z"}}"""
        )

        val snapshot = grimmoryEbookProgressSnapshot(body, null)!!
        assertEquals(1f, snapshot.percentage, 0.0001f)
        assertTrue(snapshot.finished)
    }

    @Test
    fun oidcUsernameComesFromUsersMe() {
        assertEquals(
            "reader",
            grimmoryOidcUsername("""{"id":1,"username":"reader","name":"Reader","locale":"en","provisioningMethod":"LOCAL","defaultPassword":false}"""),
        )
    }
}
