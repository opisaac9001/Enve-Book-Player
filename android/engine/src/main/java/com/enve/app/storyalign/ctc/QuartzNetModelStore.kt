package com.enve.app.storyalign.ctc

import android.content.Context
import com.enve.app.data.offline.withDownloadCalls
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import okhttp3.OkHttpClient
import okhttp3.Request

@Singleton
class QuartzNetModelStore @Inject constructor(@ApplicationContext context: Context) {
    private val directory = File(context.noBackupFilesDir, "storyalign/models/quartznet15x5-en-1")
    private val client = OkHttpClient()

    suspend fun prepare(onProgress: suspend (Float) -> Unit): File = DOWNLOAD_MUTEX.withLock { withContext(Dispatchers.IO) {
        directory.mkdirs()
        val context = currentCoroutineContext()
        val total = ARTIFACTS.sumOf { it.bytes }
        var completed = 0L
        for (artifact in ARTIFACTS) {
            val target = File(directory, artifact.name)
            if (target.isFile && target.length() == artifact.bytes && target.ctcSha256 { context.ensureActive() } == artifact.sha256) {
                completed += artifact.bytes
                onProgress(completed.toFloat() / total)
                continue
            }
            val partial = File(directory, artifact.name + ".part")
            val offset = partial.length().takeIf { it < artifact.bytes } ?: 0L
            val request = Request.Builder().url(BASE_URL + artifact.name)
                .apply { if (offset > 0) header("Range", "bytes=$offset-") }.build()
            try {
                client.withDownloadCalls { calls ->
                    calls.execute(request).use { response ->
                        check(response.isSuccessful) { "Alignment model download failed (HTTP ${response.code})" }
                        val body = checkNotNull(response.body) { "Empty alignment model download" }
                        val append = offset > 0 && response.code == 206
                        var written = if (append) offset else 0L
                        body.byteStream().use { input ->
                            java.io.FileOutputStream(partial, append).use { output ->
                                val buffer = ByteArray(65_536)
                                while (true) {
                                    context.ensureActive()
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    written += count
                                    check(written <= artifact.bytes) { "Alignment model download exceeds expected size" }
                                    output.write(buffer, 0, count)
                                    onProgress(((completed + written).toDouble() / total).toFloat())
                                }
                            }
                        }
                    }
                }
            } catch (error: IOException) {
                context.ensureActive()
                throw error
            }
            if (partial.length() != artifact.bytes || partial.ctcSha256 { context.ensureActive() } != artifact.sha256) {
                partial.delete()
                error("Alignment model verification failed")
            }
            check(partial.renameTo(target)) { "Could not install alignment model" }
            completed += artifact.bytes
        }
        onProgress(1f)
        directory
    } }

    private data class Artifact(val name: String, val bytes: Long, val sha256: String)

    companion object {
        private val DOWNLOAD_MUTEX = Mutex()
        const val MODEL_ID = "quartznet15x5-en-3a4cf199c53475ae-v1"
        private const val BASE_URL = "https://gitlab.com/api/v4/projects/67994333/packages/ml_models/3023100/files/"
        private val ARTIFACTS = listOf(
            Artifact("config.json", 2_856, "63817123d5a0c6821df1bc88e059c8f771e64972fb31639c2dc9594488e85418"),
            Artifact("vocab.txt", 141, "030853bf8c7ccc1e0673cd8359ccc7c91ea507d2adab6be7c7789e24013a86aa"),
            Artifact("model.onnx", 76_711_679, "3a4cf199c53475ae752694bb65989c05755bf6920d8ac8aaf51581a1021bdf2c"),
        )
    }
}

internal fun File.ctcSha256(checkCancellation: () -> Unit): String {
    val digest = MessageDigest.getInstance("SHA-256")
    inputStream().buffered().use { input ->
        val buffer = ByteArray(65_536)
        while (true) {
            checkCancellation()
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}
