package com.enve.app.data.repository

import com.enve.core.di.ApplicationScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton

internal data class CloudAudioFile(
    val id: String,
    val name: String,
    val path: String,
    val parentFolder: String?,
    val link: String,
    val size: Long?,
    val coverUrl: String? = null,
)

internal fun mergeTorBoxFiles(apiFiles: List<CloudAudioFile>, webDavFiles: List<CloudAudioFile>): List<CloudAudioFile> {
    val merged = apiFiles.associateByTo(LinkedHashMap()) { it.path.trim('/').lowercase() }
    val webDavAliases = apiFiles.groupBy { it.path.trim('/').lowercase().replace("&", "") }
    webDavFiles.forEach { file ->
        val path = file.path.trim('/').lowercase()
        val api = merged[path] ?: webDavAliases[path]?.singleOrNull()
        if (api == null) {
            merged[path] = file
        } else {
            merged[api.path.trim('/').lowercase()] = api.copy(
                size = api.size ?: file.size,
                coverUrl = api.coverUrl ?: file.coverUrl,
            )
        }
    }
    return merged.values.toList()
}

@Singleton
class TorBoxCatalogStore @Inject constructor(@ApplicationScope parentScope: CoroutineScope) {
    private val scope = CoroutineScope(SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.IO)
    private val lock = Any()
    private val accounts = mutableMapOf<String, AccountScan>()
    private val freshAccounts = mutableSetOf<String>()
    private val completed = MutableSharedFlow<String>(extraBufferCapacity = 64)
    val updates = completed.asSharedFlow()

    private class AccountScan(
        val connectionId: String?,
        val startedAt: Long,
        val api: Deferred<List<CloudAudioFile>>,
        val folders: MutableMap<List<String>, Deferred<List<CloudAudioFile>>> = mutableMapOf(),
    )

    fun invalidate() = synchronized(lock) {
        freshAccounts.addAll(accounts.keys)
        val obsolete = accounts.values.toList()
        accounts.clear()
        obsolete.forEach { scan ->
            scan.api.cancel()
            scan.folders.values.forEach { it.cancel() }
        }
    }

    fun isComplete(connectionId: String): Boolean = synchronized(lock) {
        val scans = accounts.values.filter { it.connectionId == connectionId }
        scans.isNotEmpty() && scans.all { scan ->
            scan.api.isCompleted && !scan.api.isCancelled &&
                scan.folders.values.all { it.isCompleted && !it.isCancelled }
        }
    }

    internal suspend fun files(
        connectionId: String?,
        serverUrl: String,
        token: String,
        roots: List<String>,
        awaitFolders: Boolean,
        loadApi: suspend (Boolean) -> List<CloudAudioFile>,
        loadFolders: suspend () -> List<CloudAudioFile>,
    ): Pair<List<CloudAudioFile>, List<CloudAudioFile>> {
        val key = MessageDigest.getInstance("SHA-256")
            .digest("${connectionId.orEmpty()}\n$serverUrl\n$token".toByteArray())
            .joinToString("") { "%02x".format(it) }
        val rootKey = roots.map { it.trim('/') }.distinct().sorted()
        val (scan, folders) = synchronized(lock) {
            val now = System.nanoTime()
            val cached = accounts[key]
            val scan = cached?.takeIf { now - it.startedAt < CACHE_TTL_NS }
                ?: run {
                    val fresh = freshAccounts.remove(key)
                    AccountScan(connectionId, now, scope.async { loadApi(fresh) })
                        .also { accounts[key] = it }
                }
            val coveringScan = scan.folders.entries.firstOrNull { (existingRoots, _) ->
                existingRoots.isEmpty() || (rootKey.isNotEmpty() && rootKey.all { root ->
                    existingRoots.any { root == it || root.startsWith("$it/") }
                })
            }?.value
            val folders = coveringScan ?: scan.folders.getOrPut(rootKey) {
                scope.async { loadFolders().also { scan.api.await() } }.also { task ->
                    task.invokeOnCompletion { error ->
                        if (error == null && connectionId != null && synchronized(lock) { accounts[key] === scan }) {
                            completed.tryEmit(connectionId)
                        }
                    }
                }
            }
            scan to folders
        }
        try {
            val api = scan.api.await()
            val webDav = if (awaitFolders || api.isEmpty() || folders.isCompleted) folders.await() else emptyList()
            return api to webDav
        } catch (e: CancellationException) {
            currentCoroutineContext().ensureActive()
            if (synchronized(lock) { accounts[key] !== scan }) {
                return files(connectionId, serverUrl, token, roots, awaitFolders, loadApi, loadFolders)
            }
            throw e
        } catch (e: Exception) {
            synchronized(lock) {
                if (accounts[key] === scan) {
                    accounts.remove(key)
                    scan.api.cancel()
                    scan.folders.values.forEach { it.cancel() }
                }
            }
            throw e
        }
    }

    private companion object {
        const val CACHE_TTL_NS = 300_000_000_000L
    }
}
