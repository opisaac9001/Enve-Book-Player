package com.enve.app.data.reader

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

data class StreamedComicSession(
    val cacheKey: String,
    val pageCount: Int,
    val directory: File,
    val pages: List<File>,
)

@Singleton
class ServerPageStreamingService @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val root = File(context.cacheDir, "server-comic-pages")
    private val pageLocks = ConcurrentHashMap<String, Mutex>()
    private val cleanupScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val cleanupJobs = ConcurrentHashMap<String, Job>()

    suspend fun openSession(cacheKey: String, pageCount: Int): StreamedComicSession = withContext(Dispatchers.IO) {
        val safeKey = cacheKey.replace(Regex("[^a-zA-Z0-9._-]"), "_")
        cleanupJobs.remove(safeKey)?.join()
        val directory = File(root, safeKey)
        val manifest = File(directory, "page-count")
        if (manifest.readTextOrNull()?.toIntOrNull() != pageCount) {
            directory.deleteRecursively()
        }
        directory.mkdirs()
        manifest.writeText(pageCount.toString())
        StreamedComicSession(
            cacheKey = safeKey,
            pageCount = pageCount,
            directory = directory,
            pages = List(pageCount) { index -> File(directory, "%05d.page".format(index)) },
        )
    }

    fun cachedPageIndices(session: StreamedComicSession): Set<Int> = session.pages.indices
        .filterTo(mutableSetOf()) { isUsable(session.pages[it]) }

    suspend fun ensurePage(
        session: StreamedComicSession,
        pageIndex: Int,
        fetch: suspend (pageIndex: Int, destination: File) -> Unit,
    ): File {
        require(pageIndex in session.pages.indices)
        val target = session.pages[pageIndex]
        if (isUsable(target)) return target
        val mutex = pageLocks.getOrPut(target.absolutePath) { Mutex() }
        return mutex.withLock {
            if (isUsable(target)) return@withLock target
            withContext(Dispatchers.IO) {
                val temporary = File(target.parentFile, "${target.name}.tmp")
                temporary.delete()
                try {
                    fetch(pageIndex, temporary)
                    check(isUsable(temporary)) { "Komga returned an unreadable page" }
                    if (target.exists()) target.delete()
                    if (!temporary.renameTo(target)) {
                        temporary.copyTo(target, overwrite = true)
                        temporary.delete()
                    }
                } catch (error: Throwable) {
                    temporary.delete()
                    throw error
                }
                target
            }
        }
    }

    suspend fun trimToWindow(session: StreamedComicSession, currentPage: Int, radius: Int = 3): Set<Int> =
        withContext(Dispatchers.IO) {
            val keep = ((currentPage - radius)..(currentPage + radius)).filterTo(mutableSetOf()) { it in session.pages.indices }
            session.pages.forEachIndexed { index, file ->
                if (index !in keep) {
                    file.delete()
                    File(file.parentFile, "${file.name}.tmp").delete()
                }
            }
            cachedPageIndices(session)
        }

    fun clear(session: StreamedComicSession) {
        cleanupJobs[session.cacheKey]?.cancel()
        cleanupJobs[session.cacheKey] = cleanupScope.launch {
            session.directory.deleteRecursively()
            pageLocks.keys.removeAll { it.startsWith(session.directory.absolutePath) }
            cleanupJobs.remove(session.cacheKey)
        }
    }

    private fun isUsable(file: File): Boolean = file.exists() && file.length() > 128
}

private fun File.readTextOrNull(): String? = if (isFile) runCatching { readText() }.getOrNull() else null
