package com.enve.app.data.repository

import com.enve.core.data.importing.AudiobookFileGrouping
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.URLDecoder
import java.security.MessageDigest

internal data class CloudCoverFile(
    val path: String,
    val parentFolder: String,
    val link: String,
    val rank: Int,
)

internal data class CloudBookGroup(
    val key: String,
    val title: String,
    val folderPath: String?,
    val files: List<CloudAudioFile>,
    val coverUrl: String? = null,
)

private data class CloudTitleAuthor(
    val title: String,
    val author: String?,
)

internal fun groupCloudAudioFiles(files: List<CloudAudioFile>): List<CloudBookGroup> {
    return files
        .groupBy { file ->
            file.parentFolder?.takeIf { it.isNotBlank() }?.let { "folder:${it.lowercase()}" }
                ?: "file:${file.name.substringBeforeLast('.').lowercase()}"
        }
        .flatMap { (folderKey, folderFiles) ->
            val groups = AudiobookFileGrouping.groups(
                files = folderFiles,
                name = CloudAudioFile::name,
                sizeBytes = { it.size ?: 0L },
            )
            val isCollectionFolder = groups.size > 1
            groups.map { groupedFiles ->
                val sorted = AudiobookFileGrouping.sorted(groupedFiles, CloudAudioFile::name)
                val first = sorted.first()
                val title = if (isCollectionFolder) {
                    AudiobookFileGrouping.inferredTitle(first.name)
                } else {
                    first.parentFolder?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
                        ?: first.name.substringBeforeLast('.').replace('_', ' ')
                }
                CloudBookGroup(
                    key = if (isCollectionFolder) "file:${first.path.lowercase()}" else folderKey,
                    title = title,
                    folderPath = first.parentFolder,
                    files = sorted,
                    coverUrl = if (isCollectionFolder) null else sorted.firstNotNullOfOrNull { it.coverUrl },
                )
            }
        }
}

internal fun CloudBookGroup.toCloudBook(
    source: BookSource,
    libraryId: String,
    libraryName: String,
    idPrefix: String,
    stableScope: String,
): Book {
    val derived = derivedCloudTitleAuthor()
    val tracks = files.mapIndexed { index, file ->
        AudioTrack(
            index = index,
            fileName = file.name,
            title = file.name.substringBeforeLast('.').cleanCloudDisplayName(),
            durationMs = 0L,
            fileSizeBytes = file.size ?: 0L,
            cumulativeStartMs = 0L,
            fileId = file.id,
            contentUrl = file.link,
        )
    }
    val id = "$idPrefix-${cloudStableId("$stableScope|$key")}"
    return Book(
        id = id,
        title = derived.title,
        author = derived.author,
        narrator = null,
        coverUrl = coverUrl,
        duration = 0L,
        source = source,
        mediaType = AppMediaType.AUDIOBOOK,
        libraryId = libraryId,
        libraryName = libraryName,
        audioTracks = tracks,
        hasAudio = tracks.isNotEmpty(),
    )
}

private fun CloudBookGroup.derivedCloudTitleAuthor(): CloudTitleAuthor {
    val cleanTitle = title.cleanCloudDisplayName()
    val currentSplit = splitAuthorTitle(cleanTitle)
    if (currentSplit != null) return currentSplit
    val author = folderPath
        ?.split('/')
        .orEmpty()
        .firstNotNullOfOrNull { splitAuthorTitle(it.cleanCloudDisplayName())?.author }
    return CloudTitleAuthor(title = cleanTitle, author = author)
}

private fun splitAuthorTitle(value: String): CloudTitleAuthor? {
    val parts = value.split(" - ", limit = 2)
    val author = parts.getOrNull(0)?.trim().orEmpty()
    val title = parts.getOrNull(1)?.trim().orEmpty()
    if (author.isBlank() || title.isBlank()) return null
    if (author.any { it.isDigit() } && author.length <= 5) return null
    return CloudTitleAuthor(title = title, author = author)
}

private fun String.cleanCloudDisplayName(): String =
    decodeCloudPath(this)
        .replace('_', ' ')
        .replace(Regex("\\s+"), " ")
        .trim()

internal fun decodeCloudPath(path: String): String =
    path.split('/').joinToString("/") { decodeCloudPathSegment(it) }

internal fun decodeCloudPathSegment(segment: String): String =
    runCatching { URLDecoder.decode(segment.replace("+", "%2B"), Charsets.UTF_8.name()) }
        .getOrElse { segment }

internal fun buildProviderUrl(baseUrl: String, vararg pathSegments: String): String? {
    val builder = baseUrl.toHttpUrlOrNull()?.newBuilder() ?: return null
    pathSegments.forEach { builder.addPathSegment(it) }
    return builder.build().toString()
}

internal fun isCloudAudioFile(name: String): Boolean {
    val ext = name.substringAfterLast('.', "").lowercase()
    return ext in setOf("mp3", "m4b", "m4a", "mp4", "aac", "flac", "ogg", "opus", "wav")
}

internal fun isCloudCoverFile(name: String): Boolean {
    val ext = name.substringAfterLast('.', "").lowercase()
    return ext in setOf("jpg", "jpeg", "png", "webp")
}

internal fun cloudCoverRank(name: String): Int {
    val stem = name.substringAfterLast('/').substringBeforeLast('.').lowercase()
    return when {
        stem in setOf("cover", "folder", "front", "album", "artwork") -> 0
        "cover" in stem || "folder" in stem || "front" in stem -> 1
        else -> 10
    }
}

internal fun attachCloudCovers(audioFiles: List<CloudAudioFile>, coverFiles: List<CloudCoverFile>): List<CloudAudioFile> {
    if (audioFiles.isEmpty() || coverFiles.isEmpty()) return audioFiles
    val coversByFolder = coverFiles
        .groupBy { it.parentFolder.trim('/') }
        .mapValues { (_, covers) ->
            covers.sortedWith(compareBy<CloudCoverFile> { it.rank }.thenBy { it.path.lowercase() }).first()
        }
    return audioFiles.map { file ->
        val parent = file.parentFolder?.trim('/').orEmpty()
        val cover = folderAndAncestors(parent).firstNotNullOfOrNull { coversByFolder[it] }
        if (cover == null) file else file.copy(coverUrl = cover.link)
    }
}

private fun folderAndAncestors(path: String): List<String> {
    val parts = path.split('/').filter { it.isNotBlank() }
    if (parts.isEmpty()) return emptyList()
    return parts.indices.reversed().map { index -> parts.take(index + 1).joinToString("/") }
}

internal fun filterCloudFilesByRoots(files: List<CloudAudioFile>, rootPaths: List<String>): List<CloudAudioFile> {
    val roots = normalizeCloudRootPaths(rootPaths)
    if (roots.isEmpty()) return files
    return files.filter { file ->
        val path = file.path.trim('/')
        val parent = file.parentFolder?.trim('/').orEmpty()
        roots.any { root ->
            path == root || path.startsWith("$root/") || parent == root || parent.startsWith("$root/")
        }
    }
}

internal fun normalizeCloudRootPaths(paths: List<String>): List<String> =
    paths.map { it.trim().trim('/') }
        .filter { it.isNotBlank() }
        .distinct()

internal fun cloudStableId(input: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest(input.toByteArray(Charsets.UTF_8))
    return digest.joinToString(separator = "") { byte -> "%02x".format(byte) }.take(24)
}
