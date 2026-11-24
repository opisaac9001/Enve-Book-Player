package com.enve.app.data.repository

import com.enve.app.data.remote.dto.AuthResponse
import com.enve.app.data.remote.dto.GrimmoryAppBookProgressDto
import com.enve.app.data.remote.dto.GrimmoryFileProgressDto
import com.enve.app.data.remote.dto.GrimmoryProgressRequest
import com.enve.app.data.remote.dto.LegacyBookloreBookDto
import com.enve.app.data.remote.dto.LoginRequest
import com.enve.core.reader.EpubBridgeCheckpoint
import com.enve.core.reader.EpubBridgeCheckpointCodec
import com.enve.core.reader.ReaderEngineKind
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test

class GrimmoryLiveFormatSyncTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; isLenient = true }

    @Test
    fun supportedFormatsRoundTripAgainstLab() {
        val documentPath = System.getenv("ENVE_LAB_DOCUMENT")
        assumeTrue(System.getenv("ENVE_LAB_SERVICE") == "Grimmory" && documentPath != null)
        val document = File(requireNotNull(documentPath)).readText()
        val baseUrl = System.getenv("ENVE_LAB_BASE_URL")
            ?: rowValue(document, "Grimmory") { it.startsWith("http") }
        val host = URL(baseUrl).host
        val permittedHosts = listOf("LAN address", "Tailscale address").map { rowValue(document, it) }
        check(host in permittedHosts) { "Live sync tests may only use the Enve lab" }
        val login = request(
            method = "POST",
            url = "$baseUrl/api/v1/auth/login",
            body = json.encodeToString(
                LoginRequest(
                    username = rowValue(document, "Username"),
                    password = rowValue(document, "Password"),
                ),
            ),
        )
        assertEquals(200, login.code)
        val token = json.decodeFromString<AuthResponse>(login.body).accessToken
        val fixtureSpecs = listOf(
            FixtureSpec("EPUB", "EPUB", "Enve Synthetic EPUB", "Enve Synthetic EPUB.epub"),
            FixtureSpec("PDF", "PDF", "Enve Synthetic PDF", "Enve Synthetic PDF.pdf", page = 3),
            FixtureSpec("CBX", "CBX", "Unicode 日本語 Issue", "Enve Synthetic Comic 002 - ComicInfo.cbz", page = 4),
            FixtureSpec("FB2", "FB2", "Enve Synthetic FB2", "Enve Synthetic FB2.fb2"),
            FixtureSpec("MOBI", "MOBI", "Pride and Prejudice", "Pride and Prejudice.mobi"),
            FixtureSpec("AZW3 file (server=MOBI)", "MOBI", "Adventures of Sherlock Holmes", "Sherlock Holmes.azw3"),
        )

        fixtureSpecs.map { resolveFixture(baseUrl, token, it) }.forEach { fixture ->
            val original = fetchBook(baseUrl, token, fixture.bookId)
            try {
                val locator = fixture.page?.let { page ->
                    if (fixture.bookType == "PDF") "{\"page\":$page}" else "cbz-page:$page"
                } ?: checkpoint(fixture.fileId)
                pushProgress(
                    baseUrl,
                    token,
                    fixture,
                    grimmoryEbookFileProgress(
                        bookFileId = fixture.fileId,
                        totalProgression = 0.37f,
                        checkpointValue = locator,
                        bookType = fixture.bookType,
                        page = fixture.page,
                    ),
                )
                val pulled = fetchBook(baseUrl, token, fixture.bookId)
                when (fixture.bookType) {
                    "PDF" -> {
                        assertEquals(fixture.label, fixture.page, pulled.pdfProgress?.page)
                        assertEquals(fixture.label, 37f, requireNotNull(pulled.pdfProgress?.percentage), 0.1f)
                    }
                    "CBX" -> {
                        assertEquals(fixture.label, fixture.page, pulled.cbxProgress?.page)
                        assertEquals(fixture.label, 37f, requireNotNull(pulled.cbxProgress?.percentage), 0.1f)
                    }
                    else -> {
                        assertEquals(fixture.label, CFI, pulled.epubProgress?.cfi)
                        assertEquals(fixture.label, 37f, requireNotNull(pulled.epubProgress?.percentage), 0.1f)
                    }
                }
            } finally {
                restoreEbookProgress(baseUrl, token, fixture, original)
            }
        }

        val audioFixture = resolveFixture(
            baseUrl,
            token,
            FixtureSpec("Audiobook", "AUDIOBOOK", "Chaptered M4B Book", "Enve Dual Audio First.m4b"),
        )
        val originalAudioResponse = request("GET", "$baseUrl/api/v1/app/books/${audioFixture.bookId}/progress", token)
        assertEquals(200, originalAudioResponse.code)
        val originalAudio = json.decodeFromString<GrimmoryAppBookProgressDto>(originalAudioResponse.body).audiobookProgress
        check(originalAudio != null) { "Audio round-trip requires an existing checkpoint to restore" }
        try {
            pushProgress(
                baseUrl,
                token,
                audioFixture,
                GrimmoryFileProgressDto(bookFileId = audioFixture.fileId, positionData = "23000", progressPercent = 23.0),
            )
            val audioPull = requireNotNull(fetchBook(baseUrl, token, audioFixture.bookId).audiobookProgress)
            assertEquals(23f, requireNotNull(audioPull.percentage), 0.1f)
            assertEquals(23_000L, audioPull.positionMs)
        } finally {
            pushProgress(
                baseUrl,
                token,
                audioFixture,
                GrimmoryFileProgressDto(
                    bookFileId = audioFixture.fileId,
                    positionData = originalAudio.positionMs.toString(),
                    positionHref = originalAudio.trackIndex?.toString(),
                    progressPercent = requireNotNull(originalAudio.percentage).toDouble(),
                ),
            )
        }
    }

    private fun checkpoint(fileId: Long): String = EpubBridgeCheckpointCodec.encode(
        EpubBridgeCheckpoint(
            publicationSha256 = "live-fixture",
            providerFileId = fileId.toString(),
            observedAt = 1_700_000_000_000,
            sourceEngine = ReaderEngineKind.FOLIATE,
            href = "chapter.xhtml",
            epubCfi = CFI,
            resourceProgression = 0.37,
            totalProgression = 0.37,
        ),
    )

    private fun resolveFixture(baseUrl: String, token: String, spec: FixtureSpec): Fixture {
        var pageNumber = 0
        while (true) {
            val facet = URLEncoder.encode("file_type:${spec.serverType}", StandardCharsets.UTF_8)
            val query = URLEncoder.encode(spec.search, StandardCharsets.UTF_8)
            val response = request(
                "GET",
                "$baseUrl/api/v1/books/page?facet=$facet&query=$query&sort=title&page=$pageNumber&size=100",
                token,
            )
            assertEquals(200, response.code)
            val page = json.parseToJsonElement(response.body).jsonObject
            val match = page.getValue("content").jsonArray.map { it.jsonObject }.firstNotNullOfOrNull { book ->
                val files = buildList {
                    book["primaryFile"]?.let { add(it.jsonObject) }
                    book["alternativeFormats"]?.jsonArray?.forEach { add(it.jsonObject) }
                }
                files.firstOrNull {
                    it["fileName"]?.jsonPrimitive?.contentOrNull.equals(spec.fileName, ignoreCase = true)
                }?.let { file -> book to file }
            }
            if (match != null) {
                val (book, file) = match
                return Fixture(
                    label = spec.label,
                    bookId = requireNotNull(book["id"]?.jsonPrimitive?.contentOrNull).toLong(),
                    fileId = requireNotNull(file["id"]?.jsonPrimitive?.contentOrNull).toLong(),
                    bookType = spec.serverType,
                    page = spec.page,
                )
            }
            val info = page.getValue("page").jsonObject
            val hasNext = (info["number"]?.jsonPrimitive?.intOrNull ?: 0) + 1 < (info["totalPages"]?.jsonPrimitive?.intOrNull ?: 0)
            check(hasNext) { "No ${spec.fileName} fixture found in the Grimmory lab" }
            pageNumber += 1
        }
    }

    private fun restoreEbookProgress(
        baseUrl: String,
        token: String,
        fixture: Fixture,
        original: LegacyBookloreBookDto,
    ) {
        val (positionData, percent) = when (fixture.bookType) {
            "PDF" -> original.pdfProgress?.page?.toString() to original.pdfProgress?.percentage
            "CBX" -> original.cbxProgress?.page?.toString() to original.cbxProgress?.percentage
            else -> original.epubProgress?.cfi to original.epubProgress?.percentage
        }
        pushProgress(
            baseUrl,
            token,
            fixture,
            GrimmoryFileProgressDto(
                bookFileId = fixture.fileId,
                positionData = positionData,
                positionHref = original.epubProgress?.href,
                progressPercent = (percent ?: 0f).toDouble(),
            ),
        )
    }

    private fun pushProgress(baseUrl: String, token: String, fixture: Fixture, fileProgress: GrimmoryFileProgressDto) {
        val response = request(
            method = "POST",
            url = "$baseUrl/api/v1/books/progress",
            token = token,
            body = json.encodeToString(GrimmoryProgressRequest(bookId = fixture.bookId, fileProgress = fileProgress)),
        )
        check(response.code in 200..204) { "${fixture.label} progress push returned HTTP ${response.code}" }
    }

    private fun fetchBook(baseUrl: String, token: String, bookId: Long): LegacyBookloreBookDto {
        val response = request("GET", "$baseUrl/api/v1/books/$bookId", token)
        assertEquals(200, response.code)
        return json.decodeFromString(response.body)
    }

    private fun request(method: String, url: String, token: String? = null, body: String? = null): Response {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.requestMethod = method
        connection.connectTimeout = 8_000
        connection.readTimeout = 15_000
        connection.setRequestProperty("Accept", "application/json")
        token?.let { connection.setRequestProperty("Authorization", "Bearer $it") }
        if (body != null) {
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            connection.outputStream.use { it.write(body.toByteArray()) }
        }
        val code = connection.responseCode
        val stream = if (code in 200..299) connection.inputStream else connection.errorStream
        val responseBody = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
        connection.disconnect()
        return Response(code, responseBody)
    }

    private fun rowValue(document: String, label: String, predicate: (String) -> Boolean = { true }): String {
        return document.lineSequence()
            .filter { it.startsWith("| $label |") }
            .flatMap { line -> Regex("`([^`]*)`").findAll(line).map { it.groupValues[1] } }
            .first(predicate)
    }

    private data class Fixture(
        val label: String,
        val bookId: Long,
        val fileId: Long,
        val bookType: String,
        val page: Int? = null,
    )

    private data class FixtureSpec(
        val label: String,
        val serverType: String,
        val search: String,
        val fileName: String,
        val page: Int? = null,
    )

    private data class Response(val code: Int, val body: String)

    private companion object {
        const val CFI = "epubcfi(/6/2!/4/2/2)"
    }
}
