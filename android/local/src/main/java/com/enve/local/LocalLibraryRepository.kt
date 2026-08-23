package com.enve.local

import android.content.Context
import android.media.MediaMetadataRetriever
import androidx.core.net.toUri
import androidx.documentfile.provider.DocumentFile
import com.enve.core.data.importing.AudiobookFileGrouping
import com.enve.core.data.local.AudiobookGroupingOverrideStore
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import com.enve.core.data.model.ReadStatus
import com.enve.core.data.provider.ProviderMetadataUpdate
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class LocalLibraryRepository @Inject constructor(
    private @ApplicationContext val context: Context,
    private val groupingOverrides: AudiobookGroupingOverrideStore,
) {
    suspend fun scanDirectory(uriString: String, sourceId: String): List<Book> = withContext(Dispatchers.IO) {
        val rootUri = uriString.toUri()
        val rootDir = DocumentFile.fromTreeUri(context, rootUri) ?: return@withContext emptyList()
        val forcedStandaloneIds = groupingOverrides.forcedStandaloneIds(BookSource.LOCAL, sourceId)

        val books = mutableListOf<Book>()
        scanRecursive(rootDir, books, forcedStandaloneIds)
        books
    }

    suspend fun updateBookMetadata(
        rootUriString: String,
        book: Book,
        metadata: ProviderMetadataUpdate,
    ): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val rootDir = DocumentFile.fromTreeUri(context, rootUriString.toUri())
                ?: error("Local library folder is no longer available")
            val target = findFileWithParent(rootDir, book.id)
                ?: error("Local book file is no longer available")
            val sidecarName = LocalBookSidecarCodec.sidecarName(target.file.name ?: book.title)
            val sidecar = target.directory.findFile(sidecarName)
                ?: target.directory.createFile("application/json", sidecarName)
                ?: error("Could not create metadata sidecar")
            val encoded = LocalBookSidecarCodec.encode(
                fileName = target.file.name ?: book.title,
                metadata = metadata,
            )
            context.contentResolver.openOutputStream(sidecar.uri, "wt")
                ?.use { it.write(encoded.toByteArray(Charsets.UTF_8)) }
                ?: error("Could not open metadata sidecar for writing")
            Result.success(Unit)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    suspend fun deleteBook(rootUriString: String, book: Book): Result<Unit> = withContext(Dispatchers.IO) {
        try {
            val rootDir = DocumentFile.fromTreeUri(context, rootUriString.toUri())
                ?: error("Local library folder is no longer available")
            val target = findFileWithParent(rootDir, book.id)
                ?: error("Local book file is no longer available")
            val sidecarName = LocalBookSidecarCodec.sidecarName(target.file.name ?: book.title)
            target.directory.findFile(sidecarName)?.delete()
            if (!target.file.delete()) error("Could not delete local book file")
            Result.success(Unit)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Result.failure(e)
        }
    }

    private fun scanRecursive(directory: DocumentFile, books: MutableList<Book>, forcedStandaloneIds: Set<String>) {
        val files = directory.listFiles()
        val audioFiles = files.filter { !it.isDirectory && it.extension() in audioExtensions }
        val audioGroups = AudiobookFileGrouping.groups(
            files = audioFiles,
            name = { it.name.orEmpty() },
            sizeBytes = DocumentFile::length,
            forcedStandalone = { it.uri.toString() in forcedStandaloneIds },
        )
        val isCollectionFolder = audioGroups.size > 1

        audioGroups.forEach { group ->
            if (group.size == 1) {
                mapFileToBook(group.first(), directory)?.let(books::add)
            } else {
                mapAudioFolderToBook(directory, group, useFolderIdentity = !isCollectionFolder)?.let(books::add)
            }
        }

        files.filter { it.isDirectory }.forEach { scanRecursive(it, books, forcedStandaloneIds) }
        files
            .filter { !it.isDirectory && it.extension() !in audioExtensions }
            .forEach { mapFileToBook(it, directory)?.let(books::add) }
    }

    private fun mapFileToBook(file: DocumentFile, directory: DocumentFile): Book? {
        val name = file.name ?: return null
        val extension = file.extension()

        val mediaType = when (extension) {
            "epub", "pdf" -> AppMediaType.EBOOK
            "mp3", "m4b", "m4a", "aac" -> AppMediaType.AUDIOBOOK
            "cbz", "cbr" -> AppMediaType.EBOOK
            else -> return null
        }

        val id = file.uri.toString()
        val coverUrl = if (extension == "epub") {
            runCatching { EpubCoverExtractor.extractCoverUri(context, file.uri) }.getOrNull()
        } else null

        val book = Book(
            id = id,
            title = name.substringBeforeLast("."),
            author = "Local",
            source = BookSource.LOCAL,
            mediaType = mediaType,
            readStatus = ReadStatus.UNREAD,
            addedOn = file.lastModified(),
            primaryFileType = extension.uppercase(),
            coverUrl = coverUrl,
        )
        return loadSidecar(directory, name)?.let { LocalBookSidecarCodec.apply(book, it) } ?: book
    }

    private fun mapAudioFolderToBook(
        directory: DocumentFile,
        files: List<DocumentFile>,
        useFolderIdentity: Boolean,
    ): Book? {
        val primary = files.firstOrNull() ?: return null
        val sorted = AudiobookFileGrouping.sorted(files) { it.name.orEmpty() }
        var cumulativeStartMs = 0L
        val tracks = sorted.mapIndexed { index, file ->
            val metadata = readAudioMetadata(file)
            AudioTrack(
                index = index,
                fileName = file.name.orEmpty(),
                title = metadata.title ?: file.name.orEmpty().substringBeforeLast("."),
                durationMs = metadata.durationMs,
                cumulativeStartMs = cumulativeStartMs.also { cumulativeStartMs += metadata.durationMs },
                fileId = file.uri.toString(),
                contentUrl = file.uri.toString(),
            )
        }
        val chapters = tracks.mapIndexedNotNull { index, track ->
            if (track.durationMs <= 0L) return@mapIndexedNotNull null
            Chapter(
                index = index,
                title = track.title ?: track.fileName.substringBeforeLast("."),
                startTime = track.cumulativeStartMs / 1_000L,
                endTime = (track.cumulativeStartMs + track.durationMs) / 1_000L,
            )
        }
        val book = Book(
            id = primary.uri.toString(),
            title = if (useFolderIdentity) {
                directory.name?.takeIf { it.isNotBlank() }
                    ?: primary.name.orEmpty().substringBeforeLast(".")
            } else {
                AudiobookFileGrouping.inferredTitle(primary.name.orEmpty())
            },
            author = "Local",
            source = BookSource.LOCAL,
            mediaType = AppMediaType.AUDIOBOOK,
            readStatus = ReadStatus.UNREAD,
            addedOn = primary.lastModified(),
            primaryFileType = primary.extension().uppercase(),
            coverUrl = if (useFolderIdentity) folderCoverUri(directory) else null,
            duration = cumulativeStartMs / 1_000L,
            chapters = chapters,
            audioTracks = tracks,
        )
        return loadSidecar(directory, primary.name.orEmpty())?.let { LocalBookSidecarCodec.apply(book, it) } ?: book
    }

    private fun readAudioMetadata(file: DocumentFile): LocalAudioMetadata {
        val retriever = MediaMetadataRetriever()
        return try {
            context.contentResolver.openFileDescriptor(file.uri, "r")?.use { descriptor ->
                retriever.setDataSource(descriptor.fileDescriptor)
            } ?: return LocalAudioMetadata()
            LocalAudioMetadata(
                durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L,
                title = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE),
            )
        } catch (_: Exception) {
            LocalAudioMetadata()
        } finally {
            retriever.release()
        }
    }

    private fun folderCoverUri(directory: DocumentFile): String? {
        val priority = listOf("cover", "folder", "front", "album", "artwork")
        val images = directory.listFiles().filter { !it.isDirectory && it.extension() in coverExtensions }
        return images
            .sortedBy { file ->
                priority.indexOf(file.name.orEmpty().substringBeforeLast(".").lowercase()).let {
                    if (it >= 0) it else Int.MAX_VALUE
                }
            }
            .firstOrNull()
            ?.uri
            ?.toString()
    }

    private fun DocumentFile.extension(): String = name.orEmpty().substringAfterLast(".", "").lowercase()

    private fun loadSidecar(directory: DocumentFile, fileName: String): LocalBookMetadataSidecar? {
        val sidecar = directory.findFile(LocalBookSidecarCodec.sidecarName(fileName)) ?: return null
        return runCatching {
            context.contentResolver.openInputStream(sidecar.uri)
                ?.bufferedReader(Charsets.UTF_8)
                ?.use { LocalBookSidecarCodec.decode(it.readText()) }
        }.getOrNull()
    }

    private fun findFileWithParent(directory: DocumentFile, uriString: String): LocalFileTarget? {
        directory.listFiles().forEach { file ->
            if (file.isDirectory) {
                findFileWithParent(file, uriString)?.let { return it }
            } else if (file.uri.toString() == uriString) {
                return LocalFileTarget(directory, file)
            }
        }
        return null
    }

    private data class LocalFileTarget(
        val directory: DocumentFile,
        val file: DocumentFile,
    )

    private data class LocalAudioMetadata(
        val durationMs: Long = 0L,
        val title: String? = null,
    )

    private companion object {
        val audioExtensions = setOf("mp3", "m4b", "m4a", "aac")
        val coverExtensions = setOf("jpg", "jpeg", "png", "webp")
    }
}
