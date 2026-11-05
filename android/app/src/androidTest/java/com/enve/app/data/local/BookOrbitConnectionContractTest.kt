package com.enve.app.data.local

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.profiles.ProfileResources
import com.enve.bookorbit.BookOrbitEndpoints
import com.enve.bookorbit.BookOrbitRepository
import com.enve.bookorbit.api.BookOrbitApi
import com.enve.bookorbit.auth.BookOrbitPasswordLogin
import com.enve.bookorbit.auth.BookOrbitTokenRefreshStrategy
import com.enve.bookorbit.dto.*
import com.enve.core.data.local.ProfileServerSyncStore
import com.enve.core.data.model.ConnectionAuthMode
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.DynamicUrlInterceptor
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.remote.TokenRefreshContext
import com.enve.core.auth.CredentialVault
import java.io.IOException
import java.lang.reflect.Proxy
import java.util.UUID
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.CancellationException
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import retrofit2.Response

@RunWith(AndroidJUnit4::class)
class BookOrbitConnectionContractTest {
    private lateinit var resources: ProfileResources
    private lateinit var endpoints: BookOrbitEndpoints
    private val orbit = ProviderConnection("orbit", BookSource.BOOKORBIT, "Orbit", "https://orbit.invalid", "reader")
    private val other = ProviderConnection("other", BookSource.GRIMMORY, "Other", "https://other.invalid", "reader")
    private val narratedFiles = listOf(
        BookOrbitFileDto(99, "jpg", "primary"),
        BookOrbitFileDto(98, "mp3", "supplementary"),
        BookOrbitFileDto(10, "EPUB", "content", mediaOverlay = BookOrbitMediaOverlayDto(true, 120.0)),
    )

    @Before fun setUp() = runBlocking {
        resources = ProfileResources.open(ApplicationProvider.getApplicationContext<Context>(), "bo-contract-${UUID.randomUUID()}")
        resources.connections.upsert(orbit)
        resources.connections.upsert(other)
        resources.preferences.setActiveConnectionId(other.id)
        endpoints = BookOrbitEndpoints(resources.preferences, resources.connections)
    }

    @After fun tearDown(): Unit = runBlocking {
        resources.close()
        resources.locations.filesDirectory.deleteRecursively()
        resources.locations.cacheDirectory.deleteRecursively()
        resources.locations.readerDatabaseFile.parentFile?.deleteRecursively()
    }

    @Test fun missingAndForeignScopesNeverBorrowAnotherConnection() {
        assertEquals(orbit, endpoints.currentConnection())
        for (scope in listOf("missing", other.id)) {
            ConnectionScope.withConnectionId(scope) {
                assertNull(endpoints.currentConnection())
                assertThrows(IllegalStateException::class.java) { endpoints.apiBaseUrl() }
            }
        }
        ConnectionScope.withConnectionId(orbit.id) {
            assertEquals("https://orbit.invalid/api/v1", endpoints.apiBaseUrl())
            assertEquals("https://orbit.invalid/api/v1/books/1/cover", endpoints.coverUrl(1))
        }
    }

    @Test fun deletedScopedConnectionsNeverRewriteApiRequestsToTheActiveServer() {
        val client = OkHttpClient.Builder()
            .addInterceptor(DynamicUrlInterceptor(resources.preferences, resources.connections))
            .addInterceptor { chain ->
                assertEquals("orbit.invalid", chain.request().url.host)
                okhttp3.Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                    .body("{}".toResponseBody()).build()
            }.build()
        val request = okhttp3.Request.Builder().url("http://localhost/api/v1/libraries").build()
        ConnectionScope.withConnectionId(orbit.id) { client.newCall(request).execute().close() }
        ConnectionScope.withConnectionId("deleted") {
            assertThrows(IOException::class.java) { client.newCall(request).execute().close() }
        }
    }

    @Test fun cardsAndDetailsUseContentFilesAndOnlyTheSelectedOverlay() = runBlocking {
        val plainFiles = listOf(
            BookOrbitFileDto(30, "pdf", "primary"),
            BookOrbitFileDto(31, "epub", "content", mediaOverlay = BookOrbitMediaOverlayDto(true)),
        )
        val files = mapOf(1 to narratedFiles, 2 to listOf(
            BookOrbitFileDto(20, "m4b", "primary"), BookOrbitFileDto(21, "epub", "content"),
        ), 3 to plainFiles)
        val repository = repository { method, args -> when (method) {
            "books" -> {
                assertEquals(listOf(BookOrbitSort("addedAt", "asc")), (args[1] as BookOrbitBooksPageRequest).sort)
                Response.success(BookOrbitBooksPageDto(items = files.map { (id, value) ->
                    BookOrbitBookCardDto(id = id, files = value)
                }, total = files.size))
            }
            "book" -> error("Use the detail repository")
            else -> error("Unexpected API: $method")
        } }
        val cards = repository.getBooks("1", 0, 50).getOrThrow()
        for (card in cards) {
            val detailRepository = repository { method, _ ->
                check(method == "book")
                Response.success(BookOrbitBookDetailDto(id = card.id.toInt(), files = files.getValue(card.id.toInt())))
            }
            val detail = detailRepository.getBook(card.id, "1").getOrThrow()
            for (book in listOf(card, detail)) {
                when (book.id) {
                    "1" -> {
                        assertEquals(AppMediaType.EBOOK, book.mediaType)
                        assertEquals("EPUB", book.primaryFileType)
                        assertTrue(book.readAlongAvailable)
                        assertTrue(book.hasAudio)
                    }
                    "2" -> {
                        assertEquals(AppMediaType.AUDIOBOOK, book.mediaType)
                        assertTrue(book.hasEbook)
                        assertFalse(book.readAlongAvailable)
                    }
                    "3" -> {
                        assertEquals("pdf", book.primaryFileType)
                        assertFalse(book.readAlongAvailable)
                    }
                }
            }
            val ebook = detailRepository.getEbookResource(card.id)!!
            assertEquals(if (card.id == "1") "10" else if (card.id == "2") "21" else "30", ebook.providerFileId)
        }
    }

    @Test fun recentBooksAskForNewestFirstInsteadOfReversingAnArbitraryPage() = runBlocking {
        val repository = repository { method, args -> when (method) {
            "libraries" -> Response.success(listOf(BookOrbitLibraryDto(1, "Books")))
            "books" -> {
                val request = args[1] as BookOrbitBooksPageRequest
                assertEquals(BookOrbitPaginationRequest(0, 3), request.pagination)
                assertEquals(listOf(BookOrbitSort("addedAt", "desc")), request.sort)
                Response.success(BookOrbitBooksPageDto(items = listOf(3, 2, 1).map { id ->
                    BookOrbitBookCardDto(id = id, files = narratedFiles, addedAt = "2026-11-0${id}T00:00:00Z")
                }, total = 203))
            }
            else -> error("Unexpected API: $method")
        } }
        assertEquals(listOf("3", "2", "1"), repository.getRecentlyAdded(3).getOrThrow().map { it.id })
    }

    @Test fun personalCollectionCreationDoesNotAskForAdministratorPrivileges() = runBlocking {
        val repository = repository { method, _ ->
            check(method == "createCollection") { "Personal collection attempted $method" }
            Response.success(BookOrbitCollectionDto(1, "Personal", isOwner = true))
        }
        assertTrue(repository.createCollection(BookOrbitCollectionRequest("Personal", "folder")).getOrThrow().isOwner)
    }

    @Test fun narrationWritesCannotMakeAnOlderTextPositionWinASyncConflict() = runBlocking {
        ProfileServerSyncStore(resources.context, resources.locations).setEnabled(true)
        var textDate: String? = "2026-11-01T00:00:00Z"
        var narrationDate: String? = "2026-11-04T00:00:00Z"
        val repository = repository { method, _ -> when (method) {
            "book" -> Response.success(BookOrbitBookDetailDto(id = 1, files = narratedFiles))
            "ebookProgress" -> Response.success(BookOrbitFileProgressDto(cfi = "epubcfi(/6/2!/4/2/2)", percentage = 42.0,
                updatedAt = "2026-11-04T00:00:00Z", textUpdatedAt = textDate, narrationUpdatedAt = narrationDate))
            else -> error("Unexpected API: $method")
        } }
        val book = repository.getBook("1", "1").getOrThrow()
        assertEquals(java.time.Instant.parse(textDate).toEpochMilli(), repository.fetchEbookProgress(book).getOrThrow()!!.updatedAt)
        textDate = null
        assertNull(repository.fetchEbookProgress(book).getOrThrow()!!.updatedAt)
        narrationDate = null
        assertEquals(java.time.Instant.parse("2026-11-04T00:00:00Z").toEpochMilli(), repository.fetchEbookProgress(book).getOrThrow()!!.updatedAt)
    }

    @Test fun refreshKeepsAccessCookiesAndTheOtherActiveAccountsCredentials() = runBlocking {
        resources.preferences.saveAuth("active-token", "active-refresh")
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            val request = chain.request()
            assertEquals("CF_Authorization=access-fixture; refresh_token=refresh-fixture", request.header("Cookie"))
            okhttp3.Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .header("Set-Cookie", "refresh_token=rotated-refresh; HttpOnly; Path=/api/v1/auth")
                .body("""{"accessToken":"rotated-token"}""".toResponseBody()).build()
        }.build()
        val strategy = BookOrbitTokenRefreshStrategy(resources.preferences, resources.vault, javax.inject.Provider { client })
        val context = TokenRefreshContext(BookSource.BOOKORBIT, orbit.serverUrl, orbit.id,
            orbit.copy(customHeaders = mapOf("Cookie" to "refresh_token=outdated; CF_Authorization=access-fixture")),
            "refresh-fixture", null, null)

        assertEquals("rotated-token", strategy.refresh(context))
        assertEquals("active-token", resources.preferences.getAccessTokenSync())
        assertEquals("active-refresh", resources.preferences.getRefreshTokenSync())
        assertEquals("rotated-token", resources.vault.get(CredentialVault.accessTokenKey(orbit.id)))
        assertEquals("rotated-refresh", resources.vault.get(CredentialVault.refreshTokenKey(orbit.id)))

        resources.preferences.setActiveConnectionId(orbit.id)
        assertEquals("rotated-token", strategy.refresh(context))
        assertEquals("active-token", resources.preferences.getAccessTokenSync())
    }

    @Test fun emptyRefreshTokensCannotReplaceWorkingCredentials() = runBlocking {
        resources.preferences.saveAuth("active-token", "active-refresh")
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            okhttp3.Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK")
                .body("""{"accessToken":""}""".toResponseBody()).build()
        }.build()
        val strategy = BookOrbitTokenRefreshStrategy(resources.preferences, resources.vault, javax.inject.Provider { client })
        val context = TokenRefreshContext(BookSource.BOOKORBIT, orbit.serverUrl, orbit.id, orbit, "fixture", null, null)
        assertNull(strategy.refresh(context))
        assertEquals("active-token", resources.preferences.getAccessTokenSync())
        assertNull(resources.vault.get(CredentialVault.accessTokenKey(orbit.id)))
    }

    @Test fun failedSsoRefreshNeverBorrowsAPasswordFromAnotherLogin() {
        var requests = 0
        val client = OkHttpClient.Builder().addInterceptor { chain ->
            requests++
            assertTrue(chain.request().url.encodedPath.endsWith("/auth/refresh"))
            okhttp3.Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(401).message("Unauthorized")
                .body("{}".toResponseBody()).build()
        }.build()
        val strategy = BookOrbitTokenRefreshStrategy(resources.preferences, resources.vault, javax.inject.Provider { client })
        val context = TokenRefreshContext(BookSource.BOOKORBIT, orbit.serverUrl, orbit.id,
            orbit.copy(authMode = ConnectionAuthMode.SSO), "expired", "other-login", "other-password")
        assertNull(strategy.refresh(context))
        assertEquals(1, requests)
    }

    @Test fun passwordLoginPropagatesCancellation() {
        val api = Proxy.newProxyInstance(BookOrbitApi::class.java.classLoader, arrayOf(BookOrbitApi::class.java)) { _, _, _ ->
            throw CancellationException("cancelled")
        } as BookOrbitApi
        val login = BookOrbitPasswordLogin(api, resources.preferences, resources.vault)
        assertThrows(CancellationException::class.java) {
            runBlocking { login.login(orbit.serverUrl, "reader", "fixture") }
        }
        assertNull(resources.preferences.getAccessTokenSync())
    }

    private fun repository(response: (String, Array<out Any?>) -> Any): BookOrbitRepository {
        val api = Proxy.newProxyInstance(BookOrbitApi::class.java.classLoader, arrayOf(BookOrbitApi::class.java)) { _, method, args ->
            response(method.name, args ?: emptyArray())
        } as BookOrbitApi
        return BookOrbitRepository(api, endpoints, ProfileServerSyncStore(resources.context, resources.locations))
    }
}
