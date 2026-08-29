package com.enve.app.playback

import android.content.Context
import android.graphics.Bitmap
import android.graphics.drawable.BitmapDrawable
import android.net.Uri
import androidx.core.graphics.drawable.toBitmap
import coil.ImageLoader
import coil.request.ImageRequest
import coil.request.SuccessResult
import com.enve.app.data.offline.OfflineDownloadManager
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AutoArtworkCache @Inject constructor(
    @ApplicationContext private val context: Context,
    private val offlineDownloadManager: OfflineDownloadManager,
    private val imageLoader: ImageLoader,
) {
    suspend fun uriFor(bookId: String, cacheKey: String, coverUrl: String?): Uri? =
        withContext(Dispatchers.IO) {
            val source = sourceFor(bookId, coverUrl) ?: return@withContext null
            val artwork = artworkFile(cacheKey, source)
            if (!artwork.isFile) {
                val sourceUri = Uri.parse(source)
                val textCoverFallback = if (sourceUri.getQueryParameter("audio") != null) {
                    sourceUri.buildUpon()
                        .clearQuery()
                        .apply {
                            sourceUri.queryParameterNames
                                .filterNot { it.equals("audio", ignoreCase = true) }
                                .forEach { name ->
                                    sourceUri.getQueryParameters(name).forEach { value ->
                                        appendQueryParameter(name, value)
                                    }
                                }
                        }
                        .build()
                        .toString()
                } else {
                    null
                }
                val bytes = fetchCoverBytes(source)
                    ?: textCoverFallback?.let { fetchCoverBytes(it) }
                    ?: return@withContext null
                artwork.parentFile?.mkdirs()
                val temporary = File.createTempFile("cover-", ".tmp", artwork.parentFile)
                try {
                    temporary.writeBytes(bytes)
                    if (!temporary.renameTo(artwork)) {
                        temporary.copyTo(artwork, overwrite = true)
                    }
                } finally {
                    temporary.delete()
                }
            }
            AutoArtworkProvider.uriFor(context, artwork.name)
        }

    fun cachedUriFor(bookId: String, cacheKey: String, coverUrl: String?): Uri? {
        val source = sourceFor(bookId, coverUrl) ?: return null
        val artwork = artworkFile(cacheKey, source)
        return artwork.takeIf(File::isFile)?.let { AutoArtworkProvider.uriFor(context, it.name) }
    }

    private fun sourceFor(bookId: String, coverUrl: String?): String? =
        offlineDownloadManager.localCoverUri(bookId)
            ?: coverUrl?.takeIf { it.isNotBlank() }

    private fun artworkFile(cacheKey: String, source: String): File {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest("v2|$cacheKey|$source".toByteArray())
            .joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) }
        return File(File(context.cacheDir, AutoArtworkProvider.CACHE_DIRECTORY), "$digest.jpg")
    }

    private suspend fun fetchCoverBytes(source: String): ByteArray? =
        withTimeoutOrNull(COVER_FETCH_TIMEOUT_MS) {
            try {
                val result = imageLoader.execute(
                    ImageRequest.Builder(context)
                        .data(source)
                        .size(COVER_TARGET_PX)
                        .allowHardware(false)
                        .build()
                )
                if (result !is SuccessResult) return@withTimeoutOrNull null
                val bitmap = (result.drawable as? BitmapDrawable)?.bitmap
                    ?: result.drawable.toBitmap()
                var compressed = byteArrayOf()
                for (quality in intArrayOf(88, 80, 70)) {
                    compressed = ByteArrayOutputStream().use { output ->
                        bitmap.compress(Bitmap.CompressFormat.JPEG, quality, output)
                        output.toByteArray()
                    }
                    if (compressed.size <= MAX_COVER_BYTES) return@withTimeoutOrNull compressed
                }
                compressed
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                null
            }
        }

    private companion object {
        const val COVER_TARGET_PX = 512
        const val COVER_FETCH_TIMEOUT_MS = 2_500L
        const val MAX_COVER_BYTES = 256 * 1024
    }
}
