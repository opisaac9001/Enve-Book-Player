package com.enve.core.data.local

import com.enve.core.data.model.Book
import com.enve.core.data.model.ProviderConnection
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import javax.inject.Inject
import javax.inject.Singleton

@Serializable
enum class PendingBookMutationKind { RATING, READ_STATUS }

@Serializable
enum class PendingBookMutationFailure { TRANSIENT, AUTH, REJECTED, UNAVAILABLE }

data class PendingBookMutationIdentity(
    val source: String,
    val connectionKey: String,
    val accountKey: String,
    val bookId: String,
    val kind: PendingBookMutationKind,
)

@Serializable
data class PendingBookMutation(
    val source: String,
    val connectionKey: String,
    val accountKey: String,
    val bookId: String,
    val kind: PendingBookMutationKind,
    val value: String,
    val revision: Long,
    val createdAt: Long,
    val attempts: Int = 0,
    val lastAttemptAt: Long = 0L,
    val failure: PendingBookMutationFailure? = null,
) {
    val identity: PendingBookMutationIdentity
        get() = PendingBookMutationIdentity(source, connectionKey, accountKey, bookId, kind)

    val connectionId: String? get() = connectionKey.takeIf(String::isNotEmpty)

    fun targets(book: Book): Boolean =
        source == book.source.name && connectionKey == book.connectionId.orEmpty() && bookId == book.id
}

fun ProviderConnection.pendingBookMutationAccountKey(): String = "${serverUrl.trimEnd('/')}|$username"

fun List<ProviderConnection>.pendingBookMutationConnection(source: String, connectionId: String?): ProviderConnection? {
    val registered = filter { it.source.name == source }
    return if (connectionId == null) registered.singleOrNull() else registered.firstOrNull { it.id == connectionId }
}

fun List<ProviderConnection>.pendingBookMutationAccountKey(source: String, connectionId: String?): String =
    pendingBookMutationConnection(source, connectionId)?.pendingBookMutationAccountKey().orEmpty()

fun List<PendingBookMutation>.forCurrentAccounts(connections: List<ProviderConnection>): List<PendingBookMutation> =
    filter { it.accountKey == connections.pendingBookMutationAccountKey(it.source, it.connectionId) }

@Singleton
class PendingBookMutationStore(private val file: File) {
    @Inject
    constructor(locations: ProfileStorageLocations) : this(
        File(locations.filesDirectory, "sync/pending_book_mutations.json"),
    )

    @Serializable
    private data class Snapshot(
        val nextRevision: Long = 1L,
        val mutations: List<PendingBookMutation> = emptyList(),
    )

    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }
    private val mutex = Mutex()
    private var snapshot = load()
    private val mutableMutations = MutableStateFlow(snapshot.mutations)

    val mutations: StateFlow<List<PendingBookMutation>> = mutableMutations.asStateFlow()

    fun find(identity: PendingBookMutationIdentity): PendingBookMutation? =
        mutableMutations.value.firstOrNull { it.identity == identity }

    fun hasPending(
        source: String,
        connectionId: String?,
        accountKey: String,
        bookId: String,
        kind: PendingBookMutationKind,
    ): Boolean = find(PendingBookMutationIdentity(source, connectionId.orEmpty(), accountKey, bookId, kind)) != null

    suspend fun enqueue(identity: PendingBookMutationIdentity, value: String, now: Long): PendingBookMutation? =
        mutex.withLock {
            val mutation = PendingBookMutation(
                source = identity.source,
                connectionKey = identity.connectionKey,
                accountKey = identity.accountKey,
                bookId = identity.bookId,
                kind = identity.kind,
                value = value,
                revision = snapshot.nextRevision,
                createdAt = now,
            )
            val updated = Snapshot(
                nextRevision = snapshot.nextRevision + 1L,
                mutations = snapshot.mutations.filterNot { it.identity == identity } + mutation,
            )
            mutation.takeIf { commit(updated) }
        }

    suspend fun acknowledge(identity: PendingBookMutationIdentity, revision: Long): Boolean = mutex.withLock {
        if (snapshot.mutations.none { it.identity == identity && it.revision == revision }) return@withLock false
        commit(snapshot.copy(mutations = snapshot.mutations.filterNot { it.identity == identity && it.revision == revision }))
    }

    suspend fun recordFailure(
        identity: PendingBookMutationIdentity,
        revision: Long,
        failure: PendingBookMutationFailure,
        now: Long,
    ): Boolean = mutex.withLock {
        if (snapshot.mutations.none { it.identity == identity && it.revision == revision }) return@withLock false
        commit(
            snapshot.copy(
                mutations = snapshot.mutations.map { mutation ->
                    if (mutation.identity != identity || mutation.revision != revision) mutation
                    else mutation.copy(
                        attempts = (mutation.attempts + 1).coerceAtMost(MAX_RECORDED_ATTEMPTS),
                        lastAttemptAt = now,
                        failure = failure,
                    )
                },
            ),
        )
    }

    private suspend fun commit(updated: Snapshot): Boolean {
        val persisted = withContext(Dispatchers.IO) { persist(updated) }
        if (persisted) {
            snapshot = updated
            mutableMutations.value = updated.mutations
        }
        return persisted
    }

    private fun load(): Snapshot {
        if (!file.exists()) return Snapshot()
        return try {
            json.decodeFromString(Snapshot.serializer(), file.readText())
        } catch (_: Exception) {
            Snapshot()
        }
    }

    private fun persist(updated: Snapshot): Boolean {
        val directory = file.parentFile ?: return false
        if (!directory.isDirectory && !directory.mkdirs()) return false
        val staged = File(directory, "${file.name}.tmp")
        return try {
            FileOutputStream(staged).use { output ->
                output.write(json.encodeToString(Snapshot.serializer(), updated).toByteArray())
                output.fd.sync()
            }
            Files.move(staged.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            true
        } catch (_: Exception) {
            staged.delete()
            false
        }
    }

    private companion object {
        const val MAX_RECORDED_ATTEMPTS = 999
    }
}
