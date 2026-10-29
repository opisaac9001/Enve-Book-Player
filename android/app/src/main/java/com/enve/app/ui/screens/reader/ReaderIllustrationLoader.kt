package com.enve.app.ui.screens.reader

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import java.io.File
import java.io.IOException
import java.util.zip.ZipFile

data class ReaderIllustration(
    val bitmap: Bitmap,
    val alt: String?,
    val caption: String?,
) {
    val description: String? get() = caption ?: alt
}

object ReaderIllustrationLoader {
    const val MAX_SOURCE_BYTES = 32 * 1024 * 1024
    const val MAX_DECODED_PIXELS = 8_000_000L

    fun sampleSizeFor(width: Int, height: Int, maxPixels: Long = MAX_DECODED_PIXELS): Int {
        if (width <= 0 || height <= 0) return 1
        var sample = 1
        while (width.toLong() * height.toLong() / (sample.toLong() * sample.toLong()) > maxPixels) sample *= 2
        return sample
    }

    fun containerPath(resource: String): String? =
        resource.trim()
            .removePrefix("/")
            .takeIf { it.isNotBlank() && !it.contains("../") }

    fun readZipEntry(file: File, path: String): ByteArray? = try {
        ZipFile(file).use { zip ->
            zip.getEntry(path)?.takeIf { it.size in 1..MAX_SOURCE_BYTES.toLong() }?.let { entry ->
                zip.getInputStream(entry).use { input ->
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(32768)
                    var count = input.read(buffer)
                    while (count >= 0) {
                        if (output.size() + count > MAX_SOURCE_BYTES) return null
                        output.write(buffer, 0, count)
                        count = input.read(buffer)
                    }
                    output.toByteArray()
                }
            }
        }
    } catch (_: IOException) {
        null
    }

    fun decode(bytes: ByteArray): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val options = BitmapFactory.Options().apply {
            inSampleSize = sampleSizeFor(bounds.outWidth, bounds.outHeight)
        }
        val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
        val orientation = try {
            android.media.ExifInterface(bytes.inputStream()).getAttributeInt(
                android.media.ExifInterface.TAG_ORIENTATION, android.media.ExifInterface.ORIENTATION_NORMAL)
        } catch (_: IOException) { android.media.ExifInterface.ORIENTATION_NORMAL }
        val transform = android.graphics.Matrix()
        when (orientation) {
            android.media.ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> transform.setScale(-1f, 1f)
            android.media.ExifInterface.ORIENTATION_ROTATE_180 -> transform.setRotate(180f)
            android.media.ExifInterface.ORIENTATION_FLIP_VERTICAL -> transform.setScale(1f, -1f)
            android.media.ExifInterface.ORIENTATION_TRANSPOSE -> { transform.setRotate(90f); transform.postScale(-1f, 1f) }
            android.media.ExifInterface.ORIENTATION_ROTATE_90 -> transform.setRotate(90f)
            android.media.ExifInterface.ORIENTATION_TRANSVERSE -> { transform.setRotate(270f); transform.postScale(-1f, 1f) }
            android.media.ExifInterface.ORIENTATION_ROTATE_270 -> transform.setRotate(270f)
            else -> return bitmap
        }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, transform, true)
            .also { if (it !== bitmap) bitmap.recycle() }
    }
}
