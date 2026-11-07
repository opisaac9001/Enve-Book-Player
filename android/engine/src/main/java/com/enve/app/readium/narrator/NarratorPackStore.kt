package com.enve.app.readium.narrator

import android.content.Context
import android.os.ParcelFileDescriptor
import com.enve.app.data.offline.withDownloadCalls
import com.enve.app.storyalign.ctc.ctcSha256
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import me.zhanghai.android.libarchive.Archive
import me.zhanghai.android.libarchive.ArchiveEntry
import me.zhanghai.android.libarchive.ArchiveException
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

internal class NarratorPackStore(context: Context) {
    private val root = File(context.noBackupFilesDir, "narrator")
    private val client = OkHttpClient()

    fun isInstalled(pack: NarratorPack): Boolean {
        val directory = directory(pack)
        return pack.assets.files.all { File(directory, it.name).length() == it.bytes }
    }

    suspend fun <T> useInstalled(pack: NarratorPack, block: (File) -> T): T = lock(pack).withLock {
        check(isInstalled(pack)) { "${pack.title} is not installed" }
        block(directory(pack))
    }

    suspend fun install(pack: NarratorPack, onProgress: (Float) -> Unit) = lock(pack).withLock {
        withContext(Dispatchers.IO) {
            val context = currentCoroutineContext()
            val checkCancellation = { context.ensureActive() }
            val assets = pack.assets
            val target = directory(pack)
            root.mkdirs()
            if (assets.files.all { File(target, it.name).matches(it, checkCancellation) }) {
                removeStale(pack, keep = target)
                onProgress(1f)
                return@withContext
            }

            val total = (pack.downloadBytes + assets.extracted.sumOf { it.bytes }).toFloat()
            var completed = 0L
            val archive = partial(pack, assets.archive.fileName)
            download(assets.archive.url, assets.archive.bytes, assets.archive.sha256, archive) {
                onProgress((completed + it) / total)
            }
            completed += assets.archive.bytes
            val downloads = assets.downloads.associateWith { file ->
                partial(pack, file.name).also { partial ->
                    download(requireNotNull(file.url), file.bytes, file.sha256, partial) {
                        onProgress((completed + it) / total)
                    }
                    completed += file.bytes
                }
            }

            val staging = File(root, "${pack.id}-staging")
            staging.deleteRecursively()
            check(staging.mkdirs()) { "Could not prepare ${pack.title}" }
            extract(archive, assets, staging, checkCancellation) {
                completed += it
                onProgress(completed / total)
            }
            downloads.forEach { (file, partial) ->
                check(partial.renameTo(File(staging, file.name))) { "Could not prepare ${pack.title}" }
            }

            val replaced = File(root, "${pack.id}-replaced")
            replaced.deleteRecursively()
            if (target.exists()) check(target.renameTo(replaced)) { "Could not replace ${pack.title}" }
            check(staging.renameTo(target)) { "Could not install ${pack.title}" }
            removeStale(pack, keep = target)
            onProgress(1f)
        }
    }

    suspend fun remove(pack: NarratorPack) = lock(pack).withLock {
        withContext(Dispatchers.IO) { removeStale(pack, keep = null) }
    }

    private fun directory(pack: NarratorPack) = File(root, "${pack.id}-${pack.assets.archive.sha256.take(12)}")

    private fun partial(pack: NarratorPack, name: String) = File(root, "${pack.id}-$name.part")

    private fun removeStale(pack: NarratorPack, keep: File?) {
        root.listFiles().orEmpty()
            .filter { it.name.startsWith("${pack.id}-") && it != keep }
            .forEach { check(it.deleteRecursively()) { "Could not remove ${it.name}" } }
    }

    private suspend fun download(url: String, bytes: Long, sha256: String, file: File, onBytes: (Long) -> Unit) {
        val context = currentCoroutineContext()
        if (file.length() > bytes) file.delete()
        val resumed = file.length() > 0
        if (file.length() < bytes) fetch(url, bytes, file, onBytes) else onBytes(bytes)
        if (file.ctcSha256 { context.ensureActive() } == sha256) return
        file.delete()
        check(resumed) { "Narrator download verification failed" }
        fetch(url, bytes, file, onBytes)
        if (file.ctcSha256 { context.ensureActive() } == sha256) return
        file.delete()
        error("Narrator download verification failed")
    }

    private suspend fun fetch(url: String, bytes: Long, file: File, onBytes: (Long) -> Unit) {
        val context = currentCoroutineContext()
        val offset = file.length()
        val request = Request.Builder().url(url)
            .apply { if (offset > 0) header("Range", "bytes=$offset-") }
            .build()
        try {
            client.withDownloadCalls { calls ->
                calls.execute(request).use { response ->
                    check(response.isSuccessful) { "Narrator download failed (HTTP ${response.code})" }
                    val body = checkNotNull(response.body) { "Empty narrator download" }
                    val append = offset > 0 && response.code == 206
                    var written = if (append) offset else 0L
                    body.byteStream().use { input ->
                        FileOutputStream(file, append).use { output ->
                            val buffer = ByteArray(65_536)
                            while (true) {
                                context.ensureActive()
                                val count = input.read(buffer)
                                if (count < 0) break
                                written += count
                                check(written <= bytes) { "Narrator download exceeds its expected size" }
                                output.write(buffer, 0, count)
                                onBytes(written)
                            }
                        }
                    }
                }
            }
        } catch (error: IOException) {
            context.ensureActive()
            throw error
        }
        check(file.length() == bytes) { "Narrator download was incomplete" }
    }

    private fun extract(
        archive: File,
        assets: NarratorAssets,
        staging: File,
        checkCancellation: () -> Unit,
        onFile: (Long) -> Unit,
    ) {
        val wanted = assets.extracted.associateBy { "${assets.archive.root}/${it.name}" }
        val found = HashSet<String>()
        val handle = Archive.readNew()
        try {
            Archive.readSupportFilterBzip2(handle)
            Archive.readSupportFormatTar(handle)
            Archive.readOpenFileName(handle, archive.absolutePath.toByteArray(), 65_536)
            while (found.size < wanted.size) {
                checkCancellation()
                val entry = try {
                    Archive.readNextHeader(handle)
                } catch (e: ArchiveException) {
                    if (e.code == Archive.ERRNO_EOF) break else throw e
                }
                if (entry == 0L) break
                val name = ArchiveEntry.pathnameUtf8(entry) ?: continue
                val file = wanted[name] ?: continue
                check(
                    ArchiveEntry.filetype(entry) == ArchiveEntry.AE_IFREG &&
                        ArchiveEntry.size(entry) == file.bytes &&
                        found.add(name)
                ) { "Unexpected $name in ${assets.archive.fileName}" }
                val output = File(staging, file.name)
                ParcelFileDescriptor.open(
                    output,
                    ParcelFileDescriptor.MODE_WRITE_ONLY or
                        ParcelFileDescriptor.MODE_CREATE or
                        ParcelFileDescriptor.MODE_TRUNCATE,
                ).use { Archive.readDataIntoFd(handle, it.fd) }
                check(output.matches(file, checkCancellation)) { "Narrator model verification failed for ${file.name}" }
                onFile(file.bytes)
            }
        } finally {
            Archive.readFree(handle)
        }
        check(found.size == wanted.size) { "${assets.archive.fileName} is missing narrator files" }
    }

    private fun File.matches(file: NarratorFile, checkCancellation: () -> Unit): Boolean =
        length() == file.bytes && ctcSha256(checkCancellation) == file.sha256

    private companion object {
        val locks = NarratorPack.entries.associateWith { Mutex() }

        fun lock(pack: NarratorPack) = locks.getValue(pack)
    }
}
