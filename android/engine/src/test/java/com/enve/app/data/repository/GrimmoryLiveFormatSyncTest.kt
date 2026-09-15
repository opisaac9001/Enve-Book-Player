package com.enve.app.data.repository

import com.enve.app.data.remote.dto.AuthResponse
import com.enve.app.data.remote.dto.GrimmoryAppBookProgressDto
import com.enve.app.data.remote.dto.GrimmoryFileProgressDto
import com.enve.app.data.remote.dto.GrimmoryProgressFileProgress
import com.enve.app.data.remote.dto.GrimmoryProgressRequest
import com.enve.app.data.remote.dto.GrimmoryUpdateProgressRequest
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
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assume.assumeTrue
import org.junit.Test

class GrimmoryLiveFormatSyncTest {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false }

    @Test
    fun supportedFormatsRoundTripAgainstLab() {
        val documentPath = System.getenv("ENVE_LAB_DOCUMENT")
        assumeTrue(System.getenv("ENVE_LAB_SERVICE") == "Grimmory" && documentPath != null)
        val document = File(requireNotNull(documentPath)).readText()
        val baseUrl = rowValue(document, "Grimmory") { it.startsWith("http") }
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
            val original = fetchProgress(baseUrl, token, fixture.bookId)
            try {
                val locator = fixture.page?.let { page ->
                    if (fixture.bookType == "PDF") "{\"page\":$page}" else "cbz-page:$page"
                } ?: checkpoint(fixture.fileId)
                val payload = GrimmoryUpdateProgressRequest(
                    fileProgress = grimmoryEbookFileProgress(
                        bookFileId = fixture.fileId,
                        totalProgression = 0.37f,
                        checkpointValue = locator,
                        bookType = fixture.bookType,
                        page = fixture.page,
                    ),
                )
                val push = request(
                    method = "PUT",
                    url = "$baseUrl/api/v1/app/books/${fixture.bookId}/progress",
                    token = token,
                    body = json.encodeToString(payload),
                )
                check(push.code in 200..204) { "${fixture.label} push returned HTTP ${push.code}" }
                val pulled = fetchProgress(baseUrl, token, fixture.bookId)
                assertEquals(fixture.label, 0.37f, requireNotNull(pulled.readProgress), 0.001f)
                when (fixture.bookType) {
                    "PDF" -> assertEquals(fixture.label, fixture.page, pulled.pdfProgress?.page)
                    "CBX" -> assertEquals(fixture.label, fixture.page, pulled.cbxProgress?.page)
                    else -> assertEquals(fixture.label, CFI, pulled.epubProgress?.cfi)
                }
            } finally {
                restoreEbookProgress(baseUrl, token, fixture, original)
            }
        }

        val audioFixture = resolveFixture(
            baseUrl,
            token,
            FixtureSpec("Audiobook", "AUDIOBOOK", "Chaptered M4B Book", "Chaptered M4B Book.m4b"),
        )
        val originalAudio = fetchProgress(baseUrl, token, audioFixture.bookId)
        try {
            val audioPush = request(
                method = "POST",
                url = "$baseUrl/api/v1/books/progress",
                token = token,
                body = json.encodeToString(
                    GrimmoryProgressRequest(
                        bookId = audioFixture.bookId,
                        fileProgress = GrimmoryProgressFileProgress(
                            bookFileId = audioFixture.fileId,
                            positionData = "23000",
                            progressPercent = 23.0,
                        ),
                    ),
                ),
            )
            check(audioPush.code in 200..204) { "Audiobook push returned HTTP ${audioPush.code}" }
            val audioPull = fetchProgress(baseUrl, token, audioFixture.bookId)
            assertEquals(0.23f, requireNotNull(audioPull.readProgress), 0.001f)
            assertEquals(23_000L, requireNotNull(audioPull.audiobookProgress).positionMs)
        } finally {
            val originalPosition = originalAudio.audiobookProgress?.positionMs ?: 0
            val restore = request(
                method = "POST",
                url = "$baseUrl/api/v1/books/progress",
                token = token,
                body = json.encodeToString(
                    GrimmoryProgressRequest(
                        bookId = audioFixture.bookId,
                        fileProgress = GrimmoryProgressFileProgress(
                            bookFileId = audioFixture.fileId,
                            positionData = originalPosition.toString(),
                            progressPercent = (originalAudio.readProgress ?: 0f).toDouble() * 100.0,
                        ),
                    ),
                ),
            )
            check(restore.code in 200..204) { "Audiobook restore returned HTTP ${restore.code}" }
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
            val search = URLEncoder.encode(spec.search, StandardCharsets.UTF_8)
            val response = request(
                "GET",
                "$baseUrl/api/v1/app/books?fileType=${spec.serverType}&search=$search&page=$pageNumber&size=100",
                token,
            )
            assertEquals(200, response.code)
            val page = json.parseToJsonElement(response.body).jsonObject
            val summary = page.getValue("content").jsonArray.map { it.jsonObject }.firstOrNull { book ->
                val primaryFileName = book["primaryFileName"]?.jsonPrimitive?.contentOrNull
                    ?: book["primaryFile"]?.jsonObject?.get("fileName")?.jsonPrimitive?.contentOrNull
                primaryFileName.equals(spec.fileName, ignoreCase = true)
            }
            if (summary != null) {
                val bookId = requireNotNull(summary["id"]?.jsonPrimitive?.contentOrNull).toLong()
                val detailResponse = request("GET", "$baseUrl/api/v1/app/books/$bookId", token)
                assertEquals(200, detailResponse.code)
                val detail = json.parseToJsonElement(detailResponse.body).jsonObject
                val files = buildList {
                    detail["primaryFile"]?.let { add(it.jsonObject) }
                    detail["files"]?.jsonArray?.forEach { add(it.jsonObject) }
                }
                val file = requireNotNull(files.firstOrNull {
                    it["fileName"]?.jsonPrimitive?.content.equals(spec.fileName, ignoreCase = true)
                })
                return Fixture(
                    label = spec.label,
                    bookId = bookId,
                    fileId = requireNotNull(file["id"]?.jsonPrimitive?.content).toLong(),
                    bookType = spec.serverType,
                    page = spec.page,
                )
            }
            val hasNext = page["hasNext"]?.jsonPrimitive?.booleanOrNull
                ?: (pageNumber + 1 < (page["totalPages"]?.jsonPrimitive?.intOrNull ?: 0))
            check(hasNext) { "No ${spec.fileName} fixture found in the Grimmory lab" }
            pageNumber += 1
        }
    }

    private fun restoreEbookProgress(
        baseUrl: String,
        token: String,
        fixture: Fixture,
        original: GrimmoryAppBookProgressDto,
    ) {
        val positionData = when (fixture.bookType) {
            "PDF" -> original.pdfProgress?.page?.toString()
            "CBX" -> original.cbxProgress?.page?.toString()
            else -> original.epubProgress?.cfi
        }
        val restore = request(
            method = "PUT",
            url = "$baseUrl/api/v1/app/books/${fixture.bookId}/progress",
            token = token,
            body = json.encodeToString(
                GrimmoryUpdateProgressRequest(
                    fileProgress = GrimmoryFileProgressDto(
                        bookFileId = fixture.fileId,
                        positionData = positionData,
                        positionHref = original.epubProgress?.href,
                        progressPercent = (original.readProgress ?: 0f).toDouble() * 100.0,
                    ),
                ),
            ),
        )
        check(restore.code in 200..204) { "${fixture.label} restore returned HTTP ${restore.code}" }
    }

    private fun fetchProgress(baseUrl: String, token: String, bookId: Long): GrimmoryAppBookProgressDto {
        val response = request("GET", "$baseUrl/api/v1/app/books/$bookId/progress", token)
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
