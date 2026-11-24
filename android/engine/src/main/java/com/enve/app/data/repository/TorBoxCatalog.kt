package com.enve.app.data.repository

import android.util.Log
import com.enve.app.data.remote.dto.TorBoxFileDto
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.remote.ConnectionScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

data class TorBoxAccount(
    val connectionId: String?,
    val serverUrl: String,
    val token: String,
    val rootPaths: List<String>,
)

@Singleton
class TorBoxCatalog @Inject constructor(
    private val transport: TorBoxTransport,
    private val store: TorBoxCatalogStore,
) {
    fun invalidate() = store.invalidate()

    fun libraries(rootPaths: List<String>): List<Library> {
        val selectedRoots = effectiveRootPaths(rootPaths)
        if (selectedRoots.isEmpty()) {
            return listOf(Library(id = DEFAULT_LIBRARY_ID, name = DEFAULT_LIBRARY_NAME, bookCount = 0, source = BookSource.TORBOX))
        }
        return selectedRoots.map { root ->
            Library(
                id = "$LIBRARY_PREFIX${root.trim('/')}",
                name = root.substringAfterLast('/'),
                bookCount = 0,
                source = BookSource.TORBOX,
            )
        }
    }

    suspend fun books(account: TorBoxAccount, libraryId: String?): List<Book> {
        val rootPaths = libraryId
            ?.takeIf { it.startsWith(LIBRARY_PREFIX) }
            ?.let { listOf(rootFromLibraryId(it)) }
            ?: effectiveRootPaths(account.rootPaths)
        val files = audioFiles(account, rootPaths)
        val groups = groupCloudAudioFiles(files)
        Log.i(TAG, "TorBox books: roots=${rootPaths.size} files=${files.size} groups=${groups.size} library=$libraryId")
        val effectiveLibraryId = libraryId ?: DEFAULT_LIBRARY_ID
        return groups
            .map {
                it.toCloudBook(
                    source = BookSource.TORBOX,
                    libraryId = effectiveLibraryId,
                    libraryName = if (libraryId != null && libraryId.startsWith(LIBRARY_PREFIX)) {
                        rootFromLibraryId(libraryId).substringAfterLast('/')
                    } else {
                        DEFAULT_LIBRARY_NAME
                    },
                    idPrefix = "torbox",
                    stableScope = account.connectionId ?: account.serverUrl,
                )
            }
            .sortedBy { it.title.lowercase() }
    }

    suspend fun rootCandidates(account: TorBoxAccount): List<String> =
        audioFiles(account, rootPaths = emptyList(), awaitFolders = true)
            .flatMap { file ->
                val parent = file.parentFolder?.trim('/') ?: file.path.trim('/').substringBeforeLast('/', "")
                val parts = parent.split('/').filter { it.isNotBlank() }
                parts.indices.map { index -> parts.take(index + 1).joinToString("/") }
            }
            .distinct()
            .sortedWith(compareBy<String> { it.count { ch -> ch == '/' } }.thenBy { it.lowercase() })
            .take(MAX_ROOT_CANDIDATES)

    internal suspend fun audioFiles(
        account: TorBoxAccount,
        rootPaths: List<String>,
        awaitFolders: Boolean = false,
    ): List<CloudAudioFile> {
        val baseUrl = transport.baseUrl(account.serverUrl)
        val token = account.token.takeIf { it.isNotBlank() } ?: return emptyList()
        val (apiFiles, webDavFiles) = store.files(
            connectionId = account.connectionId,
            serverUrl = baseUrl,
            token = token,
            roots = rootPaths,
            awaitFolders = awaitFolders,
            loadApi = { fresh ->
                withContext(ConnectionScope.asContextElement(account.connectionId)) {
                    coroutineScope {
                        listOf(
                            async { downloadTypeAudioFiles(baseUrl, token, "torrents", "torrent_id", "tb-torrent", fresh) },
                            async { downloadTypeAudioFiles(baseUrl, token, "usenet", "usenet_id", "tb-usenet", fresh) },
                            async { downloadTypeAudioFiles(baseUrl, token, "webdl", "web_id", "tb-webdl", fresh) },
                        ).awaitAll().flatten()
                    }
                }
            },
            loadFolders = { webDavAudioFiles(token, rootPaths) },
        )
        val files = mergeTorBoxFiles(apiFiles, webDavFiles)
        val filtered = filterCloudFilesByRoots(files, rootPaths)
        Log.i(TAG, "TorBox files: api=${apiFiles.size} webdav=${webDavFiles.size} total=${files.size} filtered=${filtered.size} roots=${rootPaths.size}")
        return filtered
    }

    private suspend fun downloadTypeAudioFiles(
        baseUrl: String,
        token: String,
        typePath: String,
        idParameter: String,
        idPrefix: String,
        fresh: Boolean,
    ): List<CloudAudioFile> {
        val files = mutableListOf<CloudAudioFile>()
        val covers = mutableListOf<CloudCoverFile>()
        var offset = 0
        val seenItemIds = mutableSetOf<Long>()

        while (offset < MAX_LIST_ITEMS && files.size < MAX_AUDIO_FILES) {
            val items = transport.downloads(baseUrl, typePath, offset, fresh) ?: return files
            if (items.isEmpty()) break
            val newItems = items.filter { seenItemIds.add(it.id) }
            if (newItems.isEmpty()) break

            newItems.forEach { item ->
                val available = item.downloadPresent ?: item.downloadFinished ?: true
                if (!available) return@forEach
                val itemId = item.id.toString()
                val itemName = (item.name?.takeIf { it.isNotBlank() } ?: item.hash?.takeIf { it.isNotBlank() } ?: itemId)
                    .let(::decodeCloudPath)
                item.files.forEach { file ->
                    val fileId = file.id.toString()
                    val fullPath = displayPath(file, itemName)?.let(::decodeCloudPath) ?: return@forEach
                    val name = (file.shortName?.takeIf { it.isNotBlank() } ?: fullPath.substringAfterLast('/'))
                        .let(::decodeCloudPathSegment)
                    val link = transport.downloadUrl(baseUrl, token, typePath, idParameter, itemId, fileId)
                        ?: return@forEach
                    val parentPath = fullPath.trim('/').substringBeforeLast('/', missingDelimiterValue = "")
                        .takeIf { it.isNotBlank() }
                        ?: itemName
                    if (isCloudCoverFile(name)) {
                        covers += CloudCoverFile(
                            path = fullPath,
                            parentFolder = parentPath,
                            link = link,
                            rank = cloudCoverRank(name),
                        )
                        return@forEach
                    }
                    if (!isCloudAudioFile(name)) return@forEach
                    files += CloudAudioFile(
                        id = "$idPrefix-$itemId-$fileId",
                        name = name,
                        path = fullPath,
                        parentFolder = parentPath,
                        link = link,
                        size = file.size,
                    )
                }
            }

            offset += items.size
        }

        Log.i(TAG, "TorBox $typePath scan: items=${seenItemIds.size} audio=${files.size} covers=${covers.size}")
        return attachCloudCovers(files, covers)
    }

    private suspend fun webDavAudioFiles(token: String, rootPaths: List<String>): List<CloudAudioFile> = withContext(Dispatchers.IO) {
        val base = TorBoxTransport.WEBDAV_BASE_URL
        val roots = normalizeCloudRootPaths(rootPaths)
        val pendingDirs = ArrayDeque<String>().apply { add(base) }
        val visitedDirs = mutableSetOf<String>()
        val audioFiles = mutableListOf<CloudAudioFile>()
        val coverFiles = mutableListOf<CloudCoverFile>()

        while (pendingDirs.isNotEmpty() && visitedDirs.size < WEBDAV_MAX_DIRS && audioFiles.size < MAX_AUDIO_FILES) {
            val dir = pendingDirs.removeFirst().trimEnd('/') + "/"
            if (!visitedDirs.add(dir)) continue
            val listing = transport.webDavListing(dir, token)
            hrefsFromListing(dir, listing).forEach { href ->
                val clean = href.substringBefore('#').substringBefore('?')
                if (clean.trimEnd('/') == dir.trimEnd('/')) return@forEach
                if (clean.endsWith("/")) {
                    val path = webDavRelativePath(base, clean)?.let(::decodeCloudPath)?.trim('/')
                        ?: return@forEach
                    val selected = roots.isEmpty() || roots.any { root ->
                        path == root || path.startsWith("$root/") || root.startsWith("$path/")
                    }
                    if (selected && clean !in visitedDirs && pendingDirs.size < WEBDAV_MAX_DIRS) pendingDirs.add(clean)
                    return@forEach
                }
                val name = decodeCloudPathSegment(clean.substringAfterLast('/')).takeIf { it.isNotBlank() } ?: return@forEach
                val relativePath = webDavRelativePath(base, clean)?.let(::decodeCloudPath) ?: return@forEach
                val parent = relativePath.substringBeforeLast('/', missingDelimiterValue = "")
                    .takeIf { it.isNotBlank() }
                    ?: "TorBox WebDAV"
                val link = transport.webDavCredentialUrl(clean, token) ?: clean
                if (isCloudCoverFile(name)) {
                    coverFiles += CloudCoverFile(
                        path = relativePath,
                        parentFolder = parent,
                        link = link,
                        rank = cloudCoverRank(name),
                    )
                    return@forEach
                }
                if (!isCloudAudioFile(name)) return@forEach
                audioFiles += CloudAudioFile(
                    id = "tb-webdav-${cloudStableId(relativePath)}",
                    name = name,
                    path = relativePath,
                    parentFolder = parent,
                    link = link,
                    size = null,
                )
            }
        }

        Log.i(TAG, "TorBox WebDAV scan: dirs=${visitedDirs.size} audio=${audioFiles.size} covers=${coverFiles.size}")
        attachCloudCovers(audioFiles, coverFiles)
    }

    private fun webDavRelativePath(base: String, url: String): String? {
        val basePath = base.trimEnd('/') + "/"
        val resolved = url.substringBefore('#').substringBefore('?')
        return resolved.removePrefix(basePath)
            .trim('/')
            .takeIf { it.isNotBlank() && it != resolved }
    }

    private fun effectiveRootPaths(paths: List<String>): List<String> {
        val roots = normalizeCloudRootPaths(paths)
        if (roots.isEmpty()) return emptyList()
        val collapsed = roots
            .sortedBy { it.count { ch -> ch == '/' } }
            .filter { candidate ->
                roots.none { parent -> parent != candidate && candidate.startsWith("$parent/") }
            }
        val hadRedundantDescendants = collapsed.size != roots.size
        return if (hadRedundantDescendants && roots.size >= DEFAULT_SELECTION_ROOT_THRESHOLD) {
            emptyList()
        } else {
            collapsed
        }
    }

    private fun rootFromLibraryId(libraryId: String): String =
        libraryId.removePrefix(LIBRARY_PREFIX).trim('/')

    private fun displayPath(file: TorBoxFileDto, itemName: String): String? {
        val name = file.name?.takeIf { it.isNotBlank() }
        val shortName = file.shortName?.takeIf { it.isNotBlank() }
        return listOfNotNull(
            name?.takeIf { '/' in it },
            shortName?.let { leaf ->
                name?.takeIf { it != leaf }?.let { "$it/$leaf" }
            },
            shortName?.let { "$itemName/$it" },
            name,
            file.s3Path?.takeIf { it.isNotBlank() },
        ).firstOrNull()?.trim('/')
    }

    private companion object {
        const val TAG = "TorBoxCatalog"
        const val DEFAULT_LIBRARY_ID = "torbox-cloud"
        const val DEFAULT_LIBRARY_NAME = "TorBox Cloud"
        const val LIBRARY_PREFIX = "torbox-root:"
        const val MAX_LIST_ITEMS = 100_000
        const val MAX_AUDIO_FILES = 100_000
        const val MAX_ROOT_CANDIDATES = 5_000
        const val DEFAULT_SELECTION_ROOT_THRESHOLD = 10
        const val WEBDAV_MAX_DIRS = 2_000
    }
}
