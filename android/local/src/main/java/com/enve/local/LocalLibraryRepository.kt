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
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.coroutineContext

@Singleton
class LocalLibraryRepository @Inject constructor(
    private @ApplicationContext val context: Context,
    private val groupingOverrides: AudiobookGroupingOverrideStore,
    private val locations: com.enve.core.data.local.ProfileStorageLocations,
) {
    suspend fun scanDirectory(uriString: String, sourceId: String): List<Book> = withContext(Dispatchers.IO) {
        val rootUri = uriString.toUri()
        val rootDir = DocumentFile.fromTreeUri(context, rootUri) ?: return@withContext emptyList()
        val forcedStandaloneIds = groupingOverrides.forcedStandaloneIds(BookSource.LOCAL, sourceId)

        val books = mutableListOf<Book>()
        scanRecursive(rootDir, books, forcedStandaloneIds)
        books
    }

    suspend fun getAudioTracks(uriString: String, sourceId: String, book: Book): List<AudioTrack> = withContext(Dispatchers.IO) {
        val rootDir = DocumentFile.fromTreeUri(context, uriString.toUri()) ?: return@withContext emptyList()
        val target = findFileWithParent(rootDir, book.id) ?: return@withContext emptyList()
        val forcedStandaloneIds = groupingOverrides.forcedStandaloneIds(BookSource.LOCAL, sourceId)
        coroutineContext.ensureActive()
        val group = audioGroups(target.directory.listFiles().toList(), forcedStandaloneIds)
            .firstOrNull { files -> files.any { it.uri.toString() == book.id } }
            ?: return@withContext emptyList()
        val tracks = readAudioTracks(group)
        if (tracks.size == 1 && tracks.single().durationMs <= 0L) {
            listOf(tracks.single().copy(durationMs = book.duration * 1_000L))
        } else {
            tracks
        }
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

    private suspend fun scanRecursive(directory: DocumentFile, books: MutableList<Book>, forcedStandaloneIds: Set<String>) {
        coroutineContext.ensureActive()
        val files = directory.listFiles()
        val audioGroups = audioGroups(files.toList(), forcedStandaloneIds)
        val isCollectionFolder = audioGroups.size > 1

        audioGroups.forEach { group ->
            coroutineContext.ensureActive()
            if (group.size == 1) {
                mapFileToBook(group.first(), directory, allowFolderCover = !isCollectionFolder)?.let(books::add)
            } else {
                mapAudioFolderToBook(directory, group, useFolderIdentity = !isCollectionFolder)?.let(books::add)
            }
        }

        files.filter { it.isDirectory }.forEach { scanRecursive(it, books, forcedStandaloneIds) }
        files
            .filter { !it.isDirectory && it.extension() !in audioExtensions }
            .forEach { mapFileToBook(it, directory)?.let(books::add) }
    }

    private suspend fun mapFileToBook(file: DocumentFile, directory: DocumentFile, allowFolderCover: Boolean = false): Book? {
        coroutineContext.ensureActive()
        val name = file.name ?: return null
        val extension = file.extension()

        val mediaType = when (extension) {
            "epub", "kepub", "pdf", "azw3" -> AppMediaType.EBOOK
            "mp3", "m4b", "m4a", "aac" -> AppMediaType.AUDIOBOOK
            "cbz", "cbr" -> AppMediaType.EBOOK
            else -> return null
        }

        val id = file.uri.toString()
        val audioMetadata = if (mediaType == AppMediaType.AUDIOBOOK) readAudioMetadata(file) else null
        coroutineContext.ensureActive()
        val epubMetadata = if (extension == "epub" || extension == "kepub") {
            runCatching { EpubCoverExtractor.extractMetadata(context, file.uri, locations.cacheDirectory) }.getOrNull()
        } else null
        val coverUrl = when {
            extension == "epub" || extension == "kepub" -> epubMetadata?.coverUrl
            mediaType == AppMediaType.AUDIOBOOK -> {
                val namedCover = directory.listFiles().firstOrNull {
                    !it.isDirectory && it.extension() in coverExtensions &&
                        it.name.orEmpty().substringBeforeLast(".").equals(name.substringBeforeLast("."), ignoreCase = true)
                }?.uri?.toString()
                namedCover ?: LocalAudioCoverExtractor.extract(context, locations.filesDirectory, file.uri)
                    ?: if (allowFolderCover) folderCoverUri(directory) else null
            }
            else -> null
        }

        val book = Book(
            id = id,
            title = audioMetadata?.title ?: name.substringBeforeLast("."),
            author = audioMetadata?.author ?: "Local",
            duration = (audioMetadata?.durationMs ?: 0L) / 1000L,
            readAlongAvailable = epubMetadata?.readAlongAvailable ?: false,
            source = BookSource.LOCAL,
            mediaType = mediaType,
            readStatus = ReadStatus.UNREAD,
            addedOn = file.lastModified(),
            primaryFileType = extension.uppercase(),
            coverUrl = coverUrl,
        )
        return loadSidecar(directory, name)?.let { LocalBookSidecarCodec.apply(book, it) } ?: book
    }

    private suspend fun mapAudioFolderToBook(
        directory: DocumentFile,
        files: List<DocumentFile>,
        useFolderIdentity: Boolean,
    ): Book? {
        val primary = files.firstOrNull() ?: return null
        val tracks = readAudioTracks(files)
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
            duration = tracks.sumOf { it.durationMs } / 1_000L,
            chapters = chapters,
            audioTracks = tracks,
        )
        return loadSidecar(directory, primary.name.orEmpty())?.let { LocalBookSidecarCodec.apply(book, it) } ?: book
    }

    private fun audioGroups(files: List<DocumentFile>, forcedStandaloneIds: Set<String>): List<List<DocumentFile>> =
        AudiobookFileGrouping.groups(
            files = files.filter { !it.isDirectory && it.extension() in audioExtensions },
            name = { it.name.orEmpty() },
            sizeBytes = DocumentFile::length,
            forcedStandalone = { it.uri.toString() in forcedStandaloneIds },
        )

    private suspend fun readAudioTracks(files: List<DocumentFile>): List<AudioTrack> {
        var cumulativeStartMs = 0L
        return AudiobookFileGrouping.sorted(files) { it.name.orEmpty() }.mapIndexed { index, file ->
            coroutineContext.ensureActive()
            val metadata = readAudioMetadata(file)
            coroutineContext.ensureActive()
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
                author = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST),
            )
        } catch (e: CancellationException) {
            throw e
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

    private suspend fun findFileWithParent(directory: DocumentFile, uriString: String): LocalFileTarget? {
        coroutineContext.ensureActive()
        directory.listFiles().forEach { file ->
            coroutineContext.ensureActive()
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
        val author: String? = null,
    )

    private companion object {
        val audioExtensions = setOf("mp3", "m4b", "m4a", "aac")
        val coverExtensions = setOf("jpg", "jpeg", "png", "webp")
    }
}
