package com.enve.bookorbit

import com.enve.bookorbit.api.BookOrbitApi
import com.enve.bookorbit.dto.BookOrbitAnnotationHubPageDto
import com.enve.bookorbit.dto.BookOrbitBookCardDto
import com.enve.bookorbit.dto.BookOrbitBookDockFileDto
import com.enve.bookorbit.dto.BookOrbitBookDockFilesPageDto
import com.enve.bookorbit.dto.BookOrbitBookDockFinalizeDto
import com.enve.bookorbit.dto.BookOrbitBookDockMetadataDto
import com.enve.bookorbit.dto.BookOrbitBookDockSelectionRequest
import com.enve.bookorbit.dto.BookOrbitBookDockUpdateRequest
import com.enve.bookorbit.dto.BookOrbitBooksPageDto
import com.enve.bookorbit.dto.BookOrbitPaginationRequest
import com.enve.bookorbit.dto.BookOrbitSmartScopeBooksRequest
import com.enve.bookorbit.dto.BookOrbitSmartScopeDto
import com.enve.bookorbit.dto.BookOrbitUserDto
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import retrofit2.Response
import java.lang.reflect.Proxy

class BookOrbitToolsWireTest {
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        coerceInputValues = true
        encodeDefaults = true
    }

    private class Call(val method: String, val arguments: List<Any?>)

    private fun api(calls: MutableList<Call>, respond: (Call) -> Response<*>): BookOrbitApi = Proxy.newProxyInstance(
        BookOrbitApi::class.java.classLoader,
        arrayOf(BookOrbitApi::class.java),
    ) { _, method, arguments ->
        val call = Call(method.name, arguments.orEmpty().dropLast(1))
        calls += call
        respond(call)
    } as BookOrbitApi

    private fun toBook(card: BookOrbitBookCardDto) = Book(
        id = card.id.toString(),
        title = card.title.orEmpty(),
        source = BookSource.BOOKORBIT,
        mediaType = AppMediaType.EBOOK,
    )

    @Test
    fun smartScopeQueryBodyMatchesServerContract() {
        val first = BookOrbitSmartScopeBooksRequest(pagination = BookOrbitPaginationRequest(page = 0, size = 50))
        assertEquals("""{"sort":[],"pagination":{"page":0,"size":50}}""", json.encodeToString(first))

        val searched = first.copy(pagination = BookOrbitPaginationRequest(page = 2, size = 50), q = "dune")
        assertEquals("""{"sort":[],"pagination":{"page":2,"size":50},"q":"dune"}""", json.encodeToString(searched))
    }

    @Test
    fun smartScopesDecodeNamesCountsAndOrder(): Unit = runBlocking {
        val scopes = json.decodeFromString<List<BookOrbitSmartScopeDto>>(
            """[
              {"id":7,"userId":1,"name":"Unread sci-fi","icon":"rocket","filter":{"type":"group","rules":[]},
               "defaultSort":[],"isPublic":false,"isOwner":true,"displayOrder":2,"bookCount":14,"coverAspectRatio":"portrait"},
              {"id":3,"userId":2,"name":"Shared shelf","icon":null,"filter":null,"defaultSort":[],"isPublic":true,
               "isOwner":false,"displayOrder":1,"bookCount":null}
            ]""",
        )
        val calls = mutableListOf<Call>()
        val listed = BookOrbitSmartScopes(api(calls) { Response.success(scopes) }, ::toBook).list().getOrThrow()

        assertEquals(listOf(3, 7), listed.map { it.id })
        assertEquals(14, listed.last().bookCount)
        assertNull(listed.first().bookCount)
        assertEquals("smartScopes", calls.single().method)
    }

    @Test
    fun smartScopeBooksSendPageAndTrimmedSearchAndKeepExactTotal(): Unit = runBlocking {
        val page = json.decodeFromString<BookOrbitBooksPageDto>(
            """{"items":[{"id":11,"title":"First"},{"id":12,"title":"Second"}],"total":137,"page":2,"size":50}""",
        )
        val calls = mutableListOf<Call>()
        val scopes = BookOrbitSmartScopes(api(calls) { Response.success(page) }, ::toBook)

        val result = scopes.books(scopeId = 7, page = 2, search = "  dune  ").getOrThrow()
        assertEquals(137, result.total)
        assertEquals(2, result.page)
        assertEquals(listOf("11", "12"), result.books.map { it.id })
        val sent = calls.single()
        assertEquals("smartScopeBooks", sent.method)
        assertEquals(7, sent.arguments[0])
        assertEquals(
            BookOrbitSmartScopeBooksRequest(pagination = BookOrbitPaginationRequest(2, 50), q = "dune"),
            sent.arguments[1],
        )

        scopes.books(scopeId = 7, page = 0, search = "   ").getOrThrow()
        assertNull((calls.last().arguments[1] as BookOrbitSmartScopeBooksRequest).q)
    }

    @Test
    fun smartScopeFailureCarriesStatusInsteadOfAnEmptyList(): Unit = runBlocking {
        val calls = mutableListOf<Call>()
        val scopes = BookOrbitSmartScopes(
            api(calls) {
                Response.error<List<BookOrbitSmartScopeDto>>(
                    403,
                    """{"statusCode":403,"message":"Forbidden resource"}""".toResponseBody("application/json".toMediaType()),
                )
            },
            ::toBook,
        )

        val failure = scopes.list().exceptionOrNull() as BookOrbitRequestException
        assertEquals(403, failure.httpStatus)
        assertEquals("Forbidden resource", failure.serverMessage)
    }

    @Test
    fun bookDropFilesDecodeMetadataLayersHoldsAndDuplicates() {
        val page = json.decodeFromString<BookOrbitBookDockFilesPageDto>(
            """{"items":[{
              "id":21,"fileName":"dune.epub","fileSize":1048576,"format":"epub","status":"ready",
              "embeddedMetadata":{"title":"dune","authors":["F. Herbert"],"language":"en"},
              "fetchedMetadata":{"title":"Dune","authors":["Frank Herbert"],"publishedYear":1965,"seriesIndex":1,"hardcoverId":"h-1"},
              "selectedMetadata":{"title":"Dune (Deluxe)"},
              "targetLibraryId":4,"targetFolderId":9,"confidence":0.92,"fetchedMetadataSources":{"title":"hardcover"},
              "errorMessage":null,"metadataEditedAt":"2026-11-01T10:00:00Z","createdAt":"2026-11-01T09:00:00Z",
              "updatedAt":"2026-11-01T10:00:00Z","unitFiles":[],"dockId":null,"holdReason":"duplicate",
              "holdDetail":{"libraryId":4,"libraryName":"Main","bookId":77},"alsoIn":["Archive"]
            },{"id":22,"fileName":"broken.pdf","fileSize":null,"format":null,"status":"error",
              "embeddedMetadata":null,"selectedMetadata":null,"fetchedMetadata":null,"targetLibraryId":null,
              "targetFolderId":null,"confidence":null,"errorMessage":"Unsupported file","unitFiles":[]}],
              "total":41,"page":2,"size":30}""",
        )

        assertEquals(41, page.total)
        val ready = page.items.first()
        val effective = bookOrbitEffectiveDockMetadata(ready)
        assertEquals("Dune (Deluxe)", effective.title)
        assertEquals(listOf("Frank Herbert"), effective.authors)
        assertEquals("en", effective.language)
        assertEquals(1965, effective.publishedYear)
        assertEquals("1", effective.seriesIndex)
        assertEquals("dune", bookOrbitDockMetadata(ready.embeddedMetadata)?.title)
        assertEquals("duplicate", ready.holdReason)
        assertEquals("Main", ready.holdDetail?.libraryName)
        assertEquals(listOf("Archive"), ready.alsoIn)

        val failed = page.items.last()
        assertEquals("Unsupported file", failed.errorMessage)
        assertNull(bookOrbitDockMetadata(failed.fetchedMetadata))
        assertEquals(BookOrbitBookDockMetadataDto(), bookOrbitEffectiveDockMetadata(failed))
    }

    @Test
    fun bookDropEditsReplaceEditableFieldsAndKeepOtherSelectedKeys() {
        val current = JsonObject(
            mapOf(
                "title" to JsonPrimitive("Old"),
                "subtitle" to JsonPrimitive("Old subtitle"),
                "hardcoverId" to JsonPrimitive("h-1"),
                "coverUrl" to JsonPrimitive("http://localhost/cover.jpg"),
            ),
        )
        val merged = bookOrbitSelectedMetadata(
            BookOrbitBookDockFileDto(id = 21, selectedMetadata = current),
            BookOrbitBookDockMetadataDto(
                title = "  New title ",
                subtitle = " ",
                authors = listOf("Ann Author", " ", "Ann Author"),
                publishedYear = 2001,
                isbn13 = "978-0-00-000000-2",
                seriesName = "Saga",
                seriesIndex = "2.5",
            ),
        )

        assertEquals("New title", merged.getValue("title").jsonPrimitive.content)
        assertEquals(JsonNull, merged.getValue("subtitle"))
        assertFalse(merged.containsKey("narrators"))
        assertFalse(merged.containsKey("description"))
        assertEquals(listOf("Ann Author"), merged.getValue("authors").jsonArray.map { it.jsonPrimitive.content })
        assertEquals("2001", merged.getValue("publishedYear").jsonPrimitive.content)
        assertEquals("9780000000002", merged.getValue("isbn13").jsonPrimitive.content)
        assertEquals("2.5", merged.getValue("seriesIndex").jsonPrimitive.content)
        assertEquals("h-1", merged.getValue("hardcoverId").jsonPrimitive.content)
        assertTrue(merged.containsKey("coverUrl"))
    }

    @Test
    fun bookDropClearedFieldsOverrideEmbeddedAndFetchedMetadata(): Unit = runBlocking {
        val file = json.decodeFromString<BookOrbitBookDockFileDto>(
            """{"id":21,"fileName":"dune.epub","status":"ready",
               "embeddedMetadata":{"title":"dune","authors":["F. Herbert"],"language":"en"},
               "fetchedMetadata":{"title":"Dune","subtitle":"Book One","authors":["Frank Herbert"],"publishedYear":1965},
               "selectedMetadata":{"hardcoverId":"h-1","publisher":"Ace"}}""",
        )
        val calls = mutableListOf<Call>()
        val drop = BookOrbitBookDrop(api(calls) { Response.success(file) })

        drop.update(file, BookOrbitBookDockMetadataDto(language = "en"), targetLibraryId = null, targetFolderId = null)
            .getOrThrow()
        val request = calls.last().arguments[1] as BookOrbitBookDockUpdateRequest
        assertEquals(
            """{"selectedMetadata":{"hardcoverId":"h-1","title":null,"subtitle":null,"authors":null,""" +
                """"publisher":null,"publishedYear":null,"language":"en"}}""",
            json.encodeToString(request),
        )

        val cleared = bookOrbitEffectiveDockMetadata(file.copy(selectedMetadata = request.selectedMetadata))
        assertNull(cleared.title)
        assertNull(cleared.subtitle)
        assertTrue(cleared.authors.isEmpty())
        assertNull(cleared.publishedYear)
        assertEquals("en", cleared.language)

        val kept = bookOrbitSelectedMetadata(
            file.copy(selectedMetadata = request.selectedMetadata),
            BookOrbitBookDockMetadataDto(language = "en"),
        )
        assertEquals(JsonNull, kept.getValue("title"))
        assertEquals(JsonNull, kept.getValue("authors"))
        assertEquals("h-1", kept.getValue("hardcoverId").jsonPrimitive.content)
    }

    @Test
    fun bookDropUpdateSendsOnlyChangedDestinationAndMergedMetadata(): Unit = runBlocking {
        val file = json.decodeFromString<BookOrbitBookDockFileDto>(
            """{"id":21,"fileName":"dune.epub","status":"ready","selectedMetadata":{"hardcoverId":"h-1"},
               "targetLibraryId":4,"targetFolderId":9}""",
        )
        val calls = mutableListOf<Call>()
        val drop = BookOrbitBookDrop(api(calls) { Response.success(file) })

        drop.update(file, BookOrbitBookDockMetadataDto(title = "Dune"), targetLibraryId = 4, targetFolderId = 9).getOrThrow()
        val unchangedTarget = calls.last().arguments[1] as BookOrbitBookDockUpdateRequest
        assertNull(unchangedTarget.targetLibraryId)
        assertEquals(
            """{"selectedMetadata":{"hardcoverId":"h-1","title":"Dune"}}""",
            json.encodeToString(unchangedTarget),
        )

        drop.update(file, edits = null, targetLibraryId = 5, targetFolderId = 12).getOrThrow()
        assertEquals(21, calls.last().arguments[0])
        assertEquals(
            """{"targetLibraryId":5,"targetFolderId":12}""",
            json.encodeToString(calls.last().arguments[1] as BookOrbitBookDockUpdateRequest),
        )
    }

    @Test
    fun bookDropListQueryUsesServerPagingAndOnlyKnownStatuses(): Unit = runBlocking {
        val calls = mutableListOf<Call>()
        val drop = BookOrbitBookDrop(api(calls) { Response.success(BookOrbitBookDockFilesPageDto()) })

        drop.files(BookOrbitDockQuery(page = 3, status = "ready", search = " dune ")).getOrThrow()
        assertEquals(listOf<Any?>(3, 30, "ready", "dune", "createdAt", "desc"), calls.last().arguments)

        drop.files(BookOrbitDockQuery(page = 0, status = "fetching", search = "")).getOrThrow()
        assertEquals(listOf<Any?>(1, 30, null, null, "createdAt", "desc"), calls.last().arguments)
    }

    @Test
    fun bookDropAccessFollowsServerPermissions(): Unit = runBlocking {
        fun access(user: String) = runBlocking {
            BookOrbitBookDrop(api(mutableListOf()) { Response.success(json.decodeFromString<BookOrbitUserDto>(user)) })
                .access().getOrThrow()
        }

        val reader = access("""{"id":2,"username":"reader","isSuperuser":false,"permissions":["library_download"]}""")
        assertFalse(reader.canView)
        assertFalse(reader.canFinalize)

        val uploader = access("""{"id":3,"username":"uploader","permissions":["book_dock_access"]}""")
        assertTrue(uploader.canView)
        assertFalse(uploader.canFinalize)
        assertFalse(uploader.managesAll)

        val filer = access("""{"id":4,"username":"filer","permissions":["book_dock_access","library_upload"]}""")
        assertTrue(filer.canFinalize)

        val admin = access("""{"id":1,"username":"admin","isSuperuser":true,"permissions":[]}""")
        assertTrue(admin.canView && admin.canFinalize && admin.managesAll)
    }

    @Test
    fun bookDropApprovalReportsPartialSuccessAndDuplicates(): Unit = runBlocking {
        val body = json.decodeFromString<BookOrbitBookDockFinalizeDto>(
            """{"total":3,"succeeded":1,"failed":2,"results":[
              {"fileId":21,"fileName":"dune.epub","newName":"Dune.epub","success":true,"bookId":90},
              {"fileId":22,"fileName":"dune-copy.epub","success":false,"isDuplicate":true,"existingBookId":90,
               "message":"Already in library"},
              {"fileId":23,"fileName":"loose.pdf","success":false,"message":"No destination"}
            ]}""",
        )
        val calls = mutableListOf<Call>()
        val drop = BookOrbitBookDrop(api(calls) { Response.success(body) })

        val result = drop.finalize(listOf(21, 22, 22, 23)).getOrThrow()
        assertEquals(1, result.succeeded)
        assertEquals(2, result.failed)
        assertTrue(result.results[1].isDuplicate)
        assertEquals("No destination", result.results[2].message)
        assertEquals(BookOrbitBookDockSelectionRequest(listOf(21, 22, 23)), calls.single().arguments[0])
        assertEquals("""{"fileIds":[21,22,23]}""", json.encodeToString(calls.single().arguments[0] as BookOrbitBookDockSelectionRequest))
    }

    @Test
    fun bookDropMutationsRefuseEmptySelectionsAndSurfaceForbidden(): Unit = runBlocking {
        val calls = mutableListOf<Call>()
        val drop = BookOrbitBookDrop(
            api(calls) {
                Response.error<Unit>(
                    403,
                    """{"message":["Missing permission: library_upload"]}""".toResponseBody("application/json".toMediaType()),
                )
            },
        )

        assertTrue(drop.discard(emptyList()).exceptionOrNull() is IllegalArgumentException)
        assertTrue(calls.isEmpty())

        val failure = drop.finalize(listOf(21)).exceptionOrNull() as BookOrbitRequestException
        assertEquals(403, failure.httpStatus)
        assertEquals("Missing permission: library_upload", failure.serverMessage)
    }

    @Test
    fun highlightsSendHasNoteOnlyWhenTheToggleIsOn(): Unit = runBlocking {
        val calls = mutableListOf<Call>()
        val hub = BookOrbitAnnotationHubRepository(api(calls) { Response.success(BookOrbitAnnotationHubPageDto()) })

        hub.list(BookOrbitAnnotationHubFilter(page = 2, search = " whale ", bookId = 5, trashed = true)).getOrThrow()
        assertEquals(listOf<Any?>(2, 40, "trashed", "whale", 5, null, null, null, null, "createdAt", "desc"), calls.last().arguments)

        hub.list(BookOrbitAnnotationHubFilter(notesOnly = true)).getOrThrow()
        assertEquals(listOf<Any?>(1, 40, "active", null, null, null, null, null, true, "createdAt", "desc"), calls.last().arguments)

        hub.export(BookOrbitAnnotationHubFilter(notesOnly = false), "json")
        assertNull(calls.last().arguments[7])
        hub.export(BookOrbitAnnotationHubFilter(notesOnly = true), "json")
        assertEquals(true, calls.last().arguments[7])
    }
}
