package com.enve.app.playback

import android.util.AtomicFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException

internal class ProfileJsonFile<T>(
    private val file: File,
    private val serializer: KSerializer<T>,
    private val empty: () -> T,
) {
    suspend fun read(): T = withContext(Dispatchers.IO) {
        val atomic = AtomicFile(file)
        val bytes = try {
            atomic.readFully()
        } catch (_: FileNotFoundException) {
            return@withContext empty()
        }
        try {
            json.decodeFromString(serializer, bytes.toString(Charsets.UTF_8))
        } catch (_: IllegalArgumentException) {
            preserveCorrupt(bytes)
            atomic.delete()
            empty()
        }
    }

    suspend fun write(value: T) = withContext(Dispatchers.IO) {
        val directory = checkNotNull(file.parentFile)
        if (!directory.isDirectory && !directory.mkdirs()) throw IOException("Couldn't create ${directory.name}")
        val atomic = AtomicFile(file)
        val output = atomic.startWrite()
        try {
            output.write(json.encodeToString(serializer, value).toByteArray(Charsets.UTF_8))
            atomic.finishWrite(output)
        } catch (error: Throwable) {
            atomic.failWrite(output)
            throw error
        }
    }

    private fun preserveCorrupt(bytes: ByteArray) {
        val target = corruptCopyFile(file, System.currentTimeMillis()) { it.exists() }
        try {
            target.outputStream().use { output ->
                output.write(bytes)
                output.fd.sync()
            }
        } catch (error: IOException) {
            target.delete()
            throw IOException("Couldn't preserve unreadable ${file.name}", error)
        }
    }

    private companion object {
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    }
}

internal fun corruptCopyFile(file: File, nowMs: Long, exists: (File) -> Boolean): File =
    generateSequence(0) { it + 1 }
        .map { attempt -> File(file.path + ".corrupt-$nowMs" + if (attempt == 0) "" else "-$attempt") }
        .first { !exists(it) }
