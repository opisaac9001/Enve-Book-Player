package com.enve.app.hearth

import android.content.Context
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.audiobookshelf.AudiobookshelfRepository
import com.enve.bookorbit.BookOrbitRepository
import com.enve.bookorbit.dto.BookOrbitCollectionRequest
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.ConnectionScope
import com.enve.app.data.repository.GrimmoryRepository
import com.enve.engine.library.LibraryFacade
import com.enve.engine.library.SavedBookList
import com.enve.engine.library.SavedBooksFacade
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

@Serializable
private data class SavedMutation(val bookKey: String, val list: SavedBookList, val saved: Boolean)

@Serializable
private data class SavedState(
    val favorites: List<String> = emptyList(),
    val later: List<String> = emptyList(),
    val pending: List<SavedMutation> = emptyList(),
    val syncedConnections: Set<String> = emptySet(),
)

@Singleton
class SavedBooksFacadeImpl @Inject constructor(
    @ApplicationContext context: Context,
    private val library: LibraryFacade,
    private val connections: ConnectionRegistry,
    private val audiobookshelf: AudiobookshelfRepository,
    private val bookOrbit: BookOrbitRepository,
    private val grimmory: GrimmoryRepository,
    private val locations: ProfileStorageLocations = ProfileStorageLocations.forProfile(context, DEFAULT_ADULT_PROFILE_ID),
) : SavedBooksFacade {
    private val prefs = context.getSharedPreferences(if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) "saved_books" else "saved_books_profile_${locations.profileId}", Context.MODE_PRIVATE)
    private val json = Json { ignoreUnknownKeys = true }
    private val mutex = Mutex()
    private val restored = prefs.getString("state", null)?.let {
        runCatching { json.decodeFromString<SavedState>(it) }.getOrNull()
    } ?: SavedState()
    private val mutableSaved = MutableStateFlow(
        mapOf(SavedBookList.FAVORITES to restored.favorites, SavedBookList.LATER to restored.later),
    )
    private val mutableErrors = MutableStateFlow<Map<String, String>>(emptyMap())
    private var pending = restored.pending
    private var syncedConnections = restored.syncedConnections
    override val saved: StateFlow<Map<SavedBookList, List<String>>> = mutableSaved
    override val syncErrors: StateFlow<Map<String, String>> = mutableErrors

    override fun contains(book: Book, list: SavedBookList): Boolean =
        book.savedKeys().any { it in mutableSaved.value[list].orEmpty() }

    override suspend fun toggle(book: Book, list: SavedBookList) {
        mutex.withLock {
            val current = mutableSaved.value[list].orEmpty()
            val keys = book.savedKeys()
            val isSaved = keys.none { it in current }
            val updated = if (isSaved) listOf(book.uniqueKey) + current.filterNot { it in keys }
            else current.filterNot { it in keys }
            mutableSaved.value = mutableSaved.value + (list to updated)
            pending = pending.filterNot { it.bookKey in keys && it.list == list }
            if (book.source in remoteSources && book.connectionId != null) {
                pending += SavedMutation(book.uniqueKey, list, isSaved)
            }
            persist()
        }
        book.connectionId?.let { syncConnection(it) }
    }

    override suspend fun refresh() {
        for (connection in connections.getConnectionsSync()) {
            if (connection.enabled && connection.source in remoteSources) {
                syncConnection(connection.id)
            }
        }
    }

    private suspend fun syncConnection(connectionId: String) {
        val connection = connections.getConnectionsSync().firstOrNull { it.id == connectionId && it.enabled } ?: return
        val source = connection.source
        if (source !in remoteSources) return
        mutex.withLock {
            val books = library.allBooks.first().filter { it.connectionId == connectionId }
            val libraryIds = (library.libraries.first().filter { it.connectionId == connectionId }.map { it.id } +
                books.mapNotNull(Book::libraryId)).distinct()
            if (source == BookSource.AUDIOBOOKSHELF && libraryIds.isEmpty()) return@withLock
            try {
                withContext(ConnectionScope.asContextElement(connectionId)) {
                    if (source == BookSource.BOOKORBIT && !bookOrbit.isCurrentUserAdmin().getOrThrow()) return@withContext
                    if (connectionId !in syncedConnections) {
                        for (list in SavedBookList.entries) {
                            for (key in mutableSaved.value[list].orEmpty().filter { it.startsWith("$connectionId:") }) {
                                if (pending.none { it.bookKey == key && it.list == list }) {
                                    pending += SavedMutation(key, list, true)
                                }
                            }
                        }
                        syncedConnections = syncedConnections + connectionId
                        persist()
                    }
                    val attempted = pending.filter { it.bookKey.startsWith("$connectionId:") }
                    for (mutation in attempted) {
                        val book = books.firstOrNull { it.uniqueKey == mutation.bookKey } ?: continue
                        try {
                            setRemote(book, mutation.list, mutation.saved)
                            mutableErrors.value = mutableErrors.value - mutation.bookKey
                        } catch (e: CancellationException) {
                            throw e
                        } catch (e: Exception) {
                            mutableErrors.value = mutableErrors.value + (mutation.bookKey to (e.message ?: "Couldn't update saved books"))
                        }
                    }
                    val snapshot = remoteSnapshot(connectionId, source, books, libraryIds)
                    for (list in SavedBookList.entries) {
                        val remote = snapshot[list].orEmpty()
                        val acknowledged = attempted.filter {
                            it.list == list && (it.bookKey in remote) == it.saved && it.bookKey !in mutableErrors.value
                        }
                        pending = pending - acknowledged.toSet()
                        val visible = remote.toMutableSet()
                        pending.filter { it.list == list && it.bookKey.startsWith("$connectionId:") }.forEach {
                            if (it.saved) visible += it.bookKey else visible -= it.bookKey
                        }
                        val existing = mutableSaved.value[list].orEmpty()
                        val kept = existing.filter { !it.startsWith("$connectionId:") || it in visible }
                        mutableSaved.value = mutableSaved.value + (list to (kept + (visible - kept.toSet()).sorted()))
                    }
                    persist()
                    mutableErrors.value = mutableErrors.value - connectionId
                }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                mutableErrors.value = mutableErrors.value + (connectionId to (e.message ?: "Couldn't sync saved books"))
            }
        }
    }

    private suspend fun setRemote(book: Book, list: SavedBookList, isSaved: Boolean) {
        val name = list.remoteName(book.source)
        when (book.source) {
            BookSource.AUDIOBOOKSHELF -> audiobookshelf.setCollectionBook(book, name, isSaved).getOrThrow()
            BookSource.GRIMMORY -> grimmory.setSavedShelfBook(book, name, isSaved).getOrThrow()
            BookSource.BOOKORBIT -> {
                val bookId = book.id.toIntOrNull() ?: error("BookOrbit book ID is invalid")
                val collections = bookOrbit.getCollections().getOrThrow()
                val collection = collections.firstOrNull { it.name.equals(name, ignoreCase = true) }
                if (collection == null) {
                    if (isSaved) {
                        val created = bookOrbit.createCollection(BookOrbitCollectionRequest(name, "FolderOpen")).getOrThrow()
                        bookOrbit.addCollectionBooks(created.id, listOf(bookId)).getOrThrow()
                    }
                } else if (isSaved) {
                    bookOrbit.addCollectionBooks(collection.id, listOf(bookId)).getOrThrow()
                } else {
                    bookOrbit.removeCollectionBooks(collection.id, listOf(bookId)).getOrThrow()
                }
            }
            else -> Unit
        }
    }

    private suspend fun remoteSnapshot(
        connectionId: String,
        source: BookSource,
        books: List<Book>,
        libraryIds: List<String>,
    ): Map<SavedBookList, Set<String>> {
        val result = SavedBookList.entries.associateWith { mutableSetOf<String>() }
        when (source) {
            BookSource.AUDIOBOOKSHELF -> {
                for (libraryId in libraryIds) {
                    val collections = audiobookshelf.getCollections(libraryId).getOrThrow()
                    for (list in SavedBookList.entries) {
                        val collection = collections.firstOrNull { it.name.equals(list.remoteName(source), ignoreCase = true) }
                        if (collection != null && collection.books == null) error("Saved collection membership is missing")
                        collection?.books?.forEach { result.getValue(list) += "$connectionId:${it.id}" }
                    }
                }
            }
            BookSource.BOOKORBIT -> {
                val collections = bookOrbit.getCollections().getOrThrow()
                for (list in SavedBookList.entries) {
                    val collection = collections.firstOrNull { it.name.equals(list.remoteName(source), ignoreCase = true) } ?: continue
                    var page = 0
                    do {
                        val batch = bookOrbit.getCollectionBooks(collection.id, page, 100).getOrThrow()
                        batch.items.forEach { result.getValue(list) += "$connectionId:${it.id}" }
                        page++
                    } while (page * 100 < batch.total)
                }
            }
            BookSource.GRIMMORY -> {
                val available = books.mapTo(mutableSetOf()) { it.uniqueKey }
                for (list in SavedBookList.entries) {
                    val rawIds = grimmory.savedShelfBookIds(list.remoteName(source)).getOrThrow()
                    val existing = mutableSaved.value[list].orEmpty().toSet()
                    for (id in rawIds) {
                        val base = "$connectionId:$id"
                        val companion = "$connectionId:grimmory-ab-$id"
                        result.getValue(list) += if (companion in existing || base !in available && companion in available) companion else base
                    }
                }
            }
            else -> Unit
        }
        return result
    }

    private fun SavedBookList.remoteName(source: BookSource): String = when (this) {
            SavedBookList.FAVORITES -> if (source == BookSource.GRIMMORY) "Favorites" else "Enve Favorites"
            SavedBookList.LATER -> "Enve For Later"
    }

    private fun Book.savedKeys(): Set<String> {
        if (source != BookSource.GRIMMORY) return setOf(uniqueKey)
        val raw = id.removePrefix("grimmory-ab-")
        val prefix = connectionId ?: source.name
        return setOf("$prefix:$raw", "$prefix:grimmory-ab-$raw")
    }

    private val remoteSources = setOf(BookSource.AUDIOBOOKSHELF, BookSource.BOOKORBIT, BookSource.GRIMMORY)

    private fun persist() {
        val state = SavedState(
            favorites = mutableSaved.value[SavedBookList.FAVORITES].orEmpty(),
            later = mutableSaved.value[SavedBookList.LATER].orEmpty(),
            pending = pending,
            syncedConnections = syncedConnections,
        )
        prefs.edit().putString("state", json.encodeToString(state)).apply()
    }
}
