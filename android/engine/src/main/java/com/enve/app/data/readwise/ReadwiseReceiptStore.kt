package com.enve.app.data.readwise

import com.enve.core.data.local.ProfileStorageLocations
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import javax.inject.Inject
import javax.inject.Singleton

@Serializable
internal data class ReadwiseReceipt(val remoteId: Long, val fingerprint: String)

@Serializable
private data class ReadwiseReceipts(val accounts: Map<String, Map<String, ReadwiseReceipt>> = emptyMap())

@Singleton
class ReadwiseReceiptStore @Inject constructor(locations: ProfileStorageLocations) {
    private val file = File(locations.filesDirectory, "readwise/receipts.json")
    private val json = Json { ignoreUnknownKeys = true }
    private val mutex = Mutex()
    private var loaded: ReadwiseReceipts? = null

    internal suspend fun receipts(account: String): Map<String, ReadwiseReceipt> = mutex.withLock {
        load().accounts[account].orEmpty()
    }

    internal suspend fun record(account: String, receipts: Map<String, ReadwiseReceipt>) {
        if (receipts.isEmpty()) return
        mutex.withLock {
            val current = load()
            val merged = current.accounts[account].orEmpty() + receipts
            val updated = ReadwiseReceipts(current.accounts + (account to merged))
            persist(updated)
            loaded = updated
        }
    }

    private suspend fun load(): ReadwiseReceipts = loaded ?: withContext(Dispatchers.IO) {
        try {
            if (file.isFile) json.decodeFromString(ReadwiseReceipts.serializer(), file.readText()) else ReadwiseReceipts()
        } catch (_: IllegalArgumentException) {
            ReadwiseReceipts()
        } catch (_: IOException) {
            ReadwiseReceipts()
        }
    }.also { loaded = it }

    private suspend fun persist(receipts: ReadwiseReceipts) = withContext(Dispatchers.IO) {
        val directory = checkNotNull(file.parentFile).apply { mkdirs() }
        val temporary = File(directory, "${file.name}.tmp")
        temporary.writeText(json.encodeToString(ReadwiseReceipts.serializer(), receipts))
        Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }
}
