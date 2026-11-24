package com.enve.app.data.local

import android.content.Context
import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.app.profiles.ProfileRuntimeRegistry
import com.enve.bookorbit.BookOrbitSmartScopes
import com.enve.bookorbit.api.BookOrbitApi
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.remote.ConnectionScope
import com.enve.core.data.remote.LoginAttempt
import com.enve.core.data.remote.LoginAttemptScope
import com.enve.engine.bookorbit.*
import java.io.File
import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import retrofit2.Retrofit
import retrofit2.converter.kotlinx.serialization.asConverterFactory

@RunWith(AndroidJUnit4::class)
class BookOrbitFeatureLiveTest {
    @Test fun nativeFeatureRoundTrip(): Unit = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val fixture = File(context.filesDir, "bookorbit-features-live-test.json")
        assumeTrue("Requires isolated BookOrbit feature fixtures", fixture.isFile)
        val config = JSONObject(fixture.readText())
        val registry = ProfileRuntimeRegistry(context)
        val profileId = "bookorbit-features-${UUID.randomUUID()}"
        var component = registry.open(profileId)
        val locations = component.storageLocations()
        val staged = mutableListOf<Int>()
        val connection = ProviderConnection(UUID.randomUUID().toString(), BookSource.BOOKORBIT,
            "BookOrbit Feature Lab", config.getString("base_url"), config.getString("username"))
        var stage = "authentication"
        try {
            component.serverSync().setEnabled(true)
            val attempt = LoginAttempt(connection.serverUrl, BookSource.BOOKORBIT, emptyMap(), connection.username)
            withContext(LoginAttemptScope.asContextElement(attempt)) {
                component.passwordLogins().getValue(BookSource.BOOKORBIT)
                    .login(connection.serverUrl, connection.username, config.getString("password")).getOrThrow()
            }
            val token = checkNotNull(attempt.accessToken ?: component.preferences().getAccessTokenSync())
            component.connections().upsert(connection)
            component.preferences().setActiveConnectionId(connection.id)
            component.preferences().setActiveBookSource(BookSource.BOOKORBIT)
            component.preferences().saveServerInfo(connection.serverUrl, connection.username)
            component.vault().put(CredentialVault.accessTokenKey(connection.id), token)
            attempt.refreshToken?.let { component.vault().put(CredentialVault.refreshTokenKey(connection.id), it) }
            component.vault().put(CredentialVault.passwordKey(connection.id), config.getString("password"))
            val book = withContext(ConnectionScope.asContextElement(connection.id)) {
                val repository = component.bookOrbitRepository()
                assertFalse(repository.isCurrentUserAdmin().getOrThrow())
                assertEquals(listOf(config.getInt("library_id").toString()), repository.getLibraries().getOrThrow().map { it.id })
                repository.getBook(config.getJSONArray("books").getInt(1).toString(), config.getInt("library_id").toString())
                    .getOrThrow().copy(connectionId = connection.id)
            }
            component.bookCacheDao().upsert(listOf(book.toCachedBook()))

            stage = "durable pending edits"
            component.connections().upsert(connection.copy(enabled = false))
            val mutations = component.pendingBookMutations()
            mutations.setPersonalRating(book, 2)
            mutations.setPersonalRating(book, 5)
            mutations.setReadStatus(book, "ON_HOLD")
            assertEquals(2, mutations.pending.value.size)
            assertEquals(5f, component.bookCacheDao().getByIdAndConnection(book.id, connection.id)?.personalRating)
            registry.close(profileId)
            component = registry.open(profileId)
            assertEquals(2, component.pendingBookMutations().pending.value.size)
            component.connections().upsert(connection)
            component.pendingBookMutations().pending.value.toList().forEach { component.pendingBookMutations().retry(it) }
            assertTrue(component.pendingBookMutations().pending.value.isEmpty())
            withContext(ConnectionScope.asContextElement(connection.id)) {
                val remote = component.bookOrbitRepository().getBook(book.id, book.libraryId).getOrThrow()
                assertEquals(5f, remote.personalRating)
                assertEquals("ON_HOLD", remote.serverReadStatus?.uppercase())
            }

            stage = "saved scopes and paging"
            val facade = component.bookOrbit()
            val scopeId = config.getJSONArray("scope_ids").getInt(0)
            assertTrue(checkNotNull(facade.smartScopes(connection.id)).any { it.id == scopeId })
            val results = facade.smartScopeBooks(connection.id, scopeId, 0, "Enve Feature Lab Android")
            assertTrue(results.books.any { it.id == book.id })
            assertEquals(0, facade.smartScopeBooks(connection.id, config.getJSONArray("scope_ids").getInt(1), 0, "").total)
            val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
            val api = Retrofit.Builder().baseUrl(connection.serverUrl.trimEnd('/') + "/").client(component.httpClient())
                .addConverterFactory(json.asConverterFactory("application/json".toMediaType())).build().create(BookOrbitApi::class.java)
            withContext(ConnectionScope.asContextElement(connection.id)) {
                val scopes = BookOrbitSmartScopes(api, component.bookOrbitRepository())
                val first = scopes.books(scopeId, 0, size = 1).getOrThrow()
                val second = scopes.books(scopeId, 1, size = 1).getOrThrow()
                assertTrue(first.total >= 3)
                assertEquals(1, first.books.size)
                assertEquals(1, second.books.size)
                assertNotEquals(first.books.single().id, second.books.single().id)
            }

            stage = "notes-only highlights"
            val annotatedBook = config.getJSONArray("books").getInt(0)
            val all = checkNotNull(facade.highlights(connection.id, BookOrbitHighlightQuery(bookId = annotatedBook)))
            val notes = checkNotNull(facade.highlights(connection.id, BookOrbitHighlightQuery(bookId = annotatedBook, notesOnly = true)))
            assertEquals(3, all.total)
            assertEquals(2, notes.total)
            assertTrue(notes.items.all { !it.note.isNullOrBlank() })

            stage = "Book Drop access and upload"
            val access = facade.bookDropAccess(connection.id)
            assertTrue(access.canView && access.canApprove && !access.managesAll)
            val destinations = facade.bookDropLibraries(connection.id)
            assertEquals(1, destinations.size)
            val folderId = config.getInt("folder_id")
            assertTrue(destinations.single().folders.any { it.id == folderId })
            val approved = facade.importBookDropFile(connection.id,
                Uri.fromFile(File(context.filesDir, "bookorbit-features-approve.epub")).toString())
            staged += approved.id
            val rejected = facade.importBookDropFile(connection.id,
                Uri.fromFile(File(context.filesDir, "bookorbit-features-reject.epub")).toString())
            staged += rejected.id
            withTimeout(45_000) {
                while (true) {
                    val items = facade.bookDropItems(connection.id, BookOrbitBookDropQuery()).items
                    if (staged.all { id -> items.any { it.id == id && it.status == BookOrbitBookDropStatus.READY } }) break
                    delay(1_000)
                }
            }
            facade.applyFetchedBookDropMetadata(connection.id, listOf(approved.id))
            val approvalTitle = "Enve Android Native Approval ${UUID.randomUUID().toString().take(8)}"
            val edited = facade.updateBookDropItem(connection.id, approved.id,
                BookOrbitBookDropEdit(approved.metadata.copy(title = approvalTitle, authors = listOf("Enve Test Lab")),
                    config.getInt("library_id"), folderId))
            assertEquals(approvalTitle, edited.metadata.title)
            assertEquals(folderId, edited.targetFolderId)
            stage = "Book Drop partial approval and discard"
            val result = facade.approveBookDropItems(connection.id, staged.toList())
            assertEquals(2, result.total)
            assertEquals(1, result.succeeded)
            assertEquals(1, result.failed)
            assertTrue(result.results.single { it.fileId == approved.id }.success)
            assertFalse(result.results.single { it.fileId == rejected.id }.success)
            staged.remove(approved.id)
            facade.discardBookDropItems(connection.id, staged.toList())
            staged.clear()
            assertFalse(facade.bookDropItems(connection.id, BookOrbitBookDropQuery()).items.any { it.id == rejected.id })
        } catch (failure: Throwable) {
            if (failure is CancellationException) throw failure
            throw AssertionError("BookOrbit native feature verification failed at $stage: ${failure.javaClass.simpleName}")
        } finally {
            withContext(NonCancellable) {
                if (staged.isNotEmpty()) runCatching { component.bookOrbit().discardBookDropItems(connection.id, staged) }
                component.vault().clearAll()
                registry.close(profileId)
                locations.filesDirectory.deleteRecursively()
                locations.cacheDirectory.deleteRecursively()
                locations.readerDatabaseFile.parentFile?.deleteRecursively()
            }
        }
    }
}
