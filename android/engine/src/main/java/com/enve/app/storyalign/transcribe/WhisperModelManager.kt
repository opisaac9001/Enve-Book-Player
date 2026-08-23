package com.enve.app.storyalign.transcribe

import android.content.Context
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton

data class WhisperModel(
    val id: String,
    val fileName: String,
    val url: String,
    val approxBytes: Long,
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
        return f.exists() && f.length() >= (model.approxBytes * 0.98).toLong()
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

        if (partial.length() < (model.approxBytes * 0.98).toLong()) {
            partial.delete()
            throw IllegalStateException("Downloaded model too small (${partial.length()} bytes)")
        }
        if (dest.exists()) dest.delete()
        if (!partial.renameTo(dest)) throw IllegalStateException("Could not finalize model file")
        onProgress(1f)
    }

    companion object {

        val TINY_EN = WhisperModel(
            id = "tiny.en",
            fileName = "ggml-tiny.en.bin",
            url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin",
            approxBytes = 77_704_715L,
        )

        val ALL = listOf(TINY_EN)
        fun byId(id: String): WhisperModel? = ALL.firstOrNull { it.id == id }
    }
}
