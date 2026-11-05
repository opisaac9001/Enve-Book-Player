package com.enve.app.ui.screens

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.zip.ZipFile
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

internal object StorytellerReadaloudCache {
    fun recordRevision(file: File, etag: String?, lastModified: String?) {
        val revision = File(file.parentFile, ".${file.name}.revision")
        val value = etag ?: lastModified
        if (value != null) revision.writeText(value) else revision.delete()
    }

    suspend fun refresh(file: File, url: String, client: OkHttpClient): File = withContext(Dispatchers.IO) {
        val revision = File(file.parentFile, ".${file.name}.revision")
        val temporary = File(file.parentFile, "${file.name}.${UUID.randomUUID()}.part")
        try {
            val probeClient = client.newBuilder().callTimeout(15, TimeUnit.SECONDS).build()
            val remoteRevision = probeClient.newCall(Request.Builder().url(url).header("Range", "bytes=0-0").header("Cache-Control", "no-cache").build()).execute().use { response ->
                if (!response.isSuccessful) return@withContext file
                response.header("ETag") ?: response.header("Last-Modified") ?: return@withContext file
            }
            if (revision.isFile && revision.readText() == remoteRevision) return@withContext file
            val downloadClient = client.newBuilder().callTimeout(0, TimeUnit.MILLISECONDS).readTimeout(5, TimeUnit.MINUTES).build()
            downloadClient.newCall(Request.Builder().url(url).header("Cache-Control", "no-cache").build()).execute().use { response ->
                if (!response.isSuccessful) return@withContext file
                val body = response.body ?: return@withContext file
                body.byteStream().use { input ->
                    temporary.outputStream().use { output ->
                        val buffer = ByteArray(32768)
                        while (true) {
                            currentCoroutineContext().ensureActive()
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                        }
                    }
                }
                if (body.contentLength() >= 0 && temporary.length() != body.contentLength()) return@withContext file
                ZipFile(temporary).use { archive ->
                    if (archive.getEntry("META-INF/container.xml") == null) return@withContext file
                }
                currentCoroutineContext().ensureActive()
                Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
                recordRevision(file, response.header("ETag"), response.header("Last-Modified"))
            }
        } catch (_: IOException) {
            currentCoroutineContext().ensureActive()
        } finally {
            temporary.delete()
        }
        file
    }
}
