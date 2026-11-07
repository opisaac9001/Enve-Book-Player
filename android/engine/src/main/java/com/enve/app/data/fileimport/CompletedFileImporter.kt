package com.enve.app.data.fileimport

import android.media.MediaMetadataRetriever
import android.net.Uri
import androidx.room.withTransaction
import com.enve.app.data.local.ReaderDatabase
import com.enve.app.data.offline.ComicOfflineStorage
import com.enve.app.data.offline.OfflineAudioManifest
import com.enve.app.data.offline.OfflineAudioStorage
import com.enve.app.data.offline.OfflineAudioTrackManifest
import com.enve.core.data.local.BookExtras
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.local.encodeChaptersJson
import com.enve.core.data.local.toBook
import com.enve.core.data.local.toCachedBook
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Chapter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption

class CompletedFileImporter(
    private val audioStorage: OfflineAudioStorage,
    private val comicStorage: ComicOfflineStorage,
    private val database: ReaderDatabase,
    private val locations: ProfileStorageLocations,
    private val refreshCompletedDownloads: () -> Unit,
) {
    suspend fun import(item: ImportItem, onBytesCopied: (Long) -> Unit = {}): Book = withContext(Dispatchers.IO) {
        require(item.files.isNotEmpty())
        val id = ImportPlanner.bookId(item)
        val book = lockFor(id).withLock {
            val existing = completed(id, item)
            if (existing != null) {
                record(existing, emptyList())
            } else {
                requireFreeSpace(item)
                discard(id, item)
                try {
                    val (imported, chapters) = when (item) {
                        is ImportItem.Document -> importDocument(id, item.file, onBytesCopied) to emptyList()
                        is ImportItem.Audiobook -> importAudiobook(id, item, onBytesCopied)
                    }
                    record(imported, chapters)
                } catch (failure: Throwable) {
                    withContext(NonCancellable) { if (completed(id, item) == null) discard(id, item) }
                    throw failure
                }
            }
        }
        refreshCompletedDownloads()
        book
    }

    private fun lockFor(id: String): Mutex =
        locks[Math.floorMod("${locations.filesDirectory.absolutePath}\n$id".hashCode(), locks.size)]

    suspend fun importFile(file: File): Book {
        require(file.isFile && file.length() > 0L) { "The file is empty." }
        require(ImportableFormats.kind(file.name) == ImportedFileKind.EBOOK) { "${file.name} is not a supported book file." }
        return import(ImportItem.Document(ImportFile(file.name, file.length(), identity = null) { file.inputStream() }))
    }

    private fun completed(id: String, item: ImportItem): Book? = when (item) {
        is ImportItem.Document -> comicStorage.getManifest(id)?.takeIf { comicStorage.isDownloaded(id) }
        is ImportItem.Audiobook -> audioStorage.getManifest(id)?.takeIf { audioStorage.isDownloaded(id) }?.let { manifest ->
            Book(
                id = manifest.bookId,
                title = manifest.title,
                author = manifest.author,
                coverUrl = manifest.coverUrl,
                duration = manifest.tracks.sumOf { it.durationMs } / 1_000L,
                source = BookSource.LOCAL,
                mediaType = AppMediaType.AUDIOBOOK,
                hasAudio = true,
                isDownloaded = true,
                addedOn = manifest.downloadedAtEpochMs,
            )
        }
    }

    private fun discard(id: String, item: ImportItem) = when (item) {
        is ImportItem.Document -> comicStorage.removeDownload(id)
        is ImportItem.Audiobook -> audioStorage.removeDownload(id)
    }

    private fun requireFreeSpace(item: ImportItem) {
        val known = item.files.sumOf { it.sizeBytes.coerceAtLeast(0L) }
        val available = locations.filesDirectory.usableSpace
        check(available - RESERVED_BYTES >= known) { "Not enough free space to import ${item.title}." }
    }

    private suspend fun importDocument(id: String, file: ImportFile, onBytesCopied: (Long) -> Unit): Book {
        val extension = file.extension
        val temp = comicStorage.createTempFile(id, extension)
        copy(file, temp, onBytesCopied)
        val cover = comicStorage.coverFile(id)
        val epub = if (extension == "epub" || extension == "kepub") EpubPackageReader.read(temp, cover) else null
        val book = Book(
            id = id,
            title = epub?.title ?: ImportableFormats.stem(file.name),
            author = epub?.author,
            coverUrl = cover.takeIf { epub?.coverWritten == true }?.let { Uri.fromFile(it).toString() },
            readAlongAvailable = epub?.readAlongAvailable == true,
            source = BookSource.LOCAL,
            mediaType = AppMediaType.EBOOK,
            primaryFileType = extension.uppercase(),
            isDownloaded = true,
            hasEbook = true,
            addedOn = System.currentTimeMillis(),
        )
        currentCoroutineContext().ensureActive()
        comicStorage.saveManifest(book)
        comicStorage.commit(temp)
        return book
    }

    private suspend fun importAudiobook(
        id: String,
        item: ImportItem.Audiobook,
        onBytesCopied: (Long) -> Unit,
    ): Pair<Book, List<Chapter>> {
        var cumulativeMs = 0L
        var firstMetadata: AudioMetadata? = null
        val tracks = item.tracks.mapIndexed { index, file ->
            val temp = audioStorage.createTrackTempFile(id, index)
            copy(file, temp, onBytesCopied)
            val final = audioStorage.createTrackFinalFile(id, index, file.extension)
            Files.move(temp.toPath(), final.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            val metadata = readAudioMetadata(final, includePicture = index == 0)
            if (index == 0) firstMetadata = metadata
            OfflineAudioTrackManifest(
                index = index,
                title = metadata.title ?: ImportableFormats.stem(file.name),
                durationMs = metadata.durationMs,
                relativePath = audioStorage.relativePath(final),
                bytes = final.length(),
            ).also { cumulativeMs += metadata.durationMs }
        }
        val lead = firstMetadata ?: AudioMetadata()
        val cover = audioStorage.coverFile(id)
        val coverUrl = lead.picture?.let { picture ->
            cover.writeBytes(picture)
            Uri.fromFile(cover).toString()
        }
        val title = if (tracks.size == 1) lead.title ?: item.title else item.title
        val now = System.currentTimeMillis()
        var start = 0L
        val chapters = if (tracks.size > 1) {
            tracks.map { track ->
                Chapter(
                    index = track.index,
                    title = track.title ?: "Track ${track.index + 1}",
                    startTime = start / 1_000L,
                    endTime = (start + track.durationMs) / 1_000L,
                ).also { start += track.durationMs }
            }.filter { it.endTime > it.startTime }
        } else {
            emptyList()
        }
        currentCoroutineContext().ensureActive()
        audioStorage.saveManifest(
            OfflineAudioManifest(
                bookId = id,
                title = title,
                author = lead.author,
                coverUrl = coverUrl,
                source = BookSource.LOCAL.name,
                downloadedAtEpochMs = now,
                tracks = tracks,
            ),
        )
        val book = Book(
            id = id,
            title = title,
            author = lead.author,
            coverUrl = coverUrl,
            duration = cumulativeMs / 1_000L,
            source = BookSource.LOCAL,
            mediaType = AppMediaType.AUDIOBOOK,
            primaryFileType = item.tracks.first().extension.uppercase(),
            hasAudio = true,
            isDownloaded = true,
            addedOn = now,
            chapters = chapters,
        )
        return book to chapters
    }

    private suspend fun record(book: Book, chapters: List<Chapter>): Book {
        database.withTransaction {
            database.bookCacheDao().insertIfAbsent(book.toCachedBook())
            if (chapters.isNotEmpty()) {
                database.bookExtrasDao().upsert(
                    BookExtras(
                        cacheKey = book.uniqueKey,
                        chaptersJson = encodeChaptersJson(chapters),
                        updatedAt = System.currentTimeMillis(),
                    ),
                )
            }
        }
        return database.bookCacheDao().getByCacheKey(book.uniqueKey)?.toBook() ?: book
    }

    private suspend fun copy(source: ImportFile, destination: File, onBytesCopied: (Long) -> Unit) {
        var total = 0L
        source.open().use { input ->
            destination.outputStream().use { output ->
                val buffer = ByteArray(BUFFER_BYTES)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val count = input.read(buffer)
                    if (count < 0) break
                    total += count
                    check(total <= MAX_FILE_BYTES) { "${source.name} is too large to import." }
                    output.write(buffer, 0, count)
                    onBytesCopied(count.toLong())
                }
                output.fd.sync()
            }
        }
        check(total > 0L) { "${source.name} is empty." }
        check(source.sizeBytes <= 0L || total == source.sizeBytes) { "${source.name} changed while it was downloading." }
    }

    private fun readAudioMetadata(file: File, includePicture: Boolean): AudioMetadata {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.path)
            AudioMetadata(
                durationMs = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L,
                title = retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_TITLE)?.trim()?.takeIf { it.isNotEmpty() },
                author = (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ARTIST)
                    ?: retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_ALBUMARTIST))
                    ?.trim()?.takeIf { it.isNotEmpty() },
                picture = if (includePicture) retriever.embeddedPicture?.takeIf { it.size <= MAX_COVER_BYTES } else null,
            )
        } catch (_: RuntimeException) {
            AudioMetadata()
        } finally {
            retriever.release()
        }
    }

    private class AudioMetadata(
        val durationMs: Long = 0L,
        val title: String? = null,
        val author: String? = null,
        val picture: ByteArray? = null,
    )

    private companion object {
        val locks = Array(64) { Mutex() }
        const val BUFFER_BYTES = 256 * 1_024
        const val RESERVED_BYTES = 256L * 1_024L * 1_024L
        const val MAX_FILE_BYTES = 16L * 1_024L * 1_024L * 1_024L
        const val MAX_COVER_BYTES = 16 * 1_024 * 1_024
    }
}
