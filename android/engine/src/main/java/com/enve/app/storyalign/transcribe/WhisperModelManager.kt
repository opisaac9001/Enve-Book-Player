package com.enve.app.storyalign.transcribe

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton

data class WhisperModel(
    val id: String,
    val fileName: String,
    val url: String,
    val approxBytes: Long,
    val sha256: String,
)

@Singleton
class WhisperModelManager @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val client = OkHttpClient()
    private val dir: File get() = File(context.filesDir, "storyalign/models").apply { mkdirs() }

    fun modelFile(model: WhisperModel): File = File(dir, model.fileName)

    fun isInstalled(model: WhisperModel): Boolean {
        val f = modelFile(model)
        return f.isFile && f.length() == model.approxBytes && f.sha256().equals(model.sha256, ignoreCase = true)
    }

    suspend fun download(model: WhisperModel, onProgress: (Float) -> Unit) = withContext(Dispatchers.IO) {
        if (isInstalled(model)) {
            onProgress(1f)
            return@withContext
        }
        val dest = modelFile(model)
        val partial = File(dir, "${model.fileName}.part")
        val existing = if (partial.exists()) partial.length() else 0L

        val request = Request.Builder()
            .url(model.url)
            .apply { if (existing > 0) header("Range", "bytes=$existing-") }
            .build()

        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IllegalStateException("Model download failed: HTTP ${response.code}")
            val body = response.body ?: throw IllegalStateException("Empty model response")
            val total = (existing + body.contentLength()).coerceAtLeast(model.approxBytes)
            val append = response.code == 206 && existing > 0
            body.byteStream().use { input ->
                java.io.FileOutputStream(partial, append).use { output ->
                    val buf = ByteArray(1 shl 16)
                    var written = if (append) existing else 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        output.write(buf, 0, n)
                        written += n
                        onProgress((written.toFloat() / total).coerceIn(0f, 1f))
                    }
                }
            }
        }

        if (partial.length() != model.approxBytes) {
            partial.delete()
            throw IllegalStateException("Downloaded model had an unexpected size")
        }
        if (!partial.sha256().equals(model.sha256, ignoreCase = true)) {
            partial.delete()
            throw IllegalStateException("Downloaded model verification failed")
        }
        if (dest.exists()) dest.delete()
        if (!partial.renameTo(dest)) throw IllegalStateException("Could not finalize model file")
        onProgress(1f)
    }

    companion object {

        val TINY_EN = WhisperModel(
            id = "tiny.en",
            fileName = "ggml-tiny.en.bin",
            url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-tiny.en.bin",
            approxBytes = 77_704_715L,
            sha256 = "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f",
        )

        val ALL = listOf(TINY_EN)
        fun byId(id: String): WhisperModel? = ALL.firstOrNull { it.id == id }
    }
}

private fun File.sha256(): String {
    val digest = MessageDigest.getInstance("SHA-256")
    inputStream().buffered().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val count = input.read(buffer)
            if (count < 0) break
            digest.update(buffer, 0, count)
        }
    }
    return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
}
