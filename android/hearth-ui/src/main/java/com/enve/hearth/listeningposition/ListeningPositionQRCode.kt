package com.enve.hearth.listeningposition

import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import com.enve.core.listeningposition.ListeningPositionPayload
import androidx.core.content.FileProvider
import com.google.zxing.*
import com.google.zxing.common.HybridBinarizer
import com.google.zxing.multi.qrcode.QRCodeMultiReader
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import java.io.File
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

object ListeningPositionQRCode {
    const val MAX_IMAGE_BYTES = 20 * 1024 * 1024
    const val MAX_IMAGE_PIXELS = 100_000_000

    fun image(message: String): Bitmap {
        require(message.toByteArray(Charsets.UTF_8).size <= ListeningPositionPayload.MAX_ENCODED_BYTES)
        val matrix = QRCodeWriter().encode(message, BarcodeFormat.QR_CODE, 600, 600,
            mapOf(EncodeHintType.CHARACTER_SET to "UTF-8", EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 4))
        val pixels = IntArray(matrix.width * matrix.height) { index ->
            if (matrix[index % matrix.width, index / matrix.width]) android.graphics.Color.BLACK else android.graphics.Color.WHITE
        }
        return Bitmap.createBitmap(pixels, matrix.width, matrix.height, Bitmap.Config.ARGB_8888)
    }

    suspend fun messages(context: Context, uri: Uri): List<String> = withContext(Dispatchers.IO) {
        require(uri.scheme == "content") { "Unsupported image source." }
        val file = File.createTempFile("listening-position-import-", ".image", context.applicationContext.cacheDir)
        try {
            context.contentResolver.openInputStream(uri)?.use { stream ->
                file.outputStream().use { output ->
                    val buffer = ByteArray(16384)
                    var total = 0
                    while (true) {
                        currentCoroutineContext().ensureActive()
                        val count = stream.read(buffer)
                        if (count < 0) break
                        require(count > 0) { "Image could not be read." }
                        total += count
                        require(total <= MAX_IMAGE_BYTES) { "Image is too large." }
                        output.write(buffer, 0, count)
                    }
                }
            } ?: return@withContext emptyList()
            currentCoroutineContext().ensureActive()
            decodeBitmap { options -> BitmapFactory.decodeFile(file.absolutePath, options) }
        } finally { file.delete() }
    }

    fun decode(data: ByteArray): List<String> {
        require(data.size <= MAX_IMAGE_BYTES) { "Image is too large." }
        return decodeBitmap { options -> BitmapFactory.decodeByteArray(data, 0, data.size, options) }
    }

    private fun decodeBitmap(read: (BitmapFactory.Options) -> Bitmap?): List<String> {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        read(bounds)
        require(bounds.outWidth in 1..16384 && bounds.outHeight in 1..16384 && bounds.outWidth <= MAX_IMAGE_PIXELS / bounds.outHeight) { "Image dimensions are unsupported." }
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > 2048) sample *= 2
        val bitmap = read(BitmapFactory.Options().apply { inSampleSize = sample }) ?: return emptyList()
        try {
            val width = bitmap.width
            val height = bitmap.height
            val pixels = IntArray(width * height)
            bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
            bitmap.recycle()
            val binary = BinaryBitmap(HybridBinarizer(RGBLuminanceSource(width, height, pixels)))
            return try { QRCodeMultiReader().decodeMultiple(binary, mapOf(DecodeHintType.TRY_HARDER to true)).map { it.text } }
            catch (_: ReaderException) { emptyList() }
        } finally { if (!bitmap.isRecycled) bitmap.recycle() }
    }

    fun share(context: Context, bitmap: Bitmap) {
        val application = context.applicationContext
        val directory = File(application.cacheDir, "listening-position-share").apply { mkdirs() }
        directory.listFiles()?.sortedByDescending { it.lastModified() }?.drop(15)?.forEach { it.delete() }
        val file = File(directory, "${UUID.randomUUID()}.png")
        file.outputStream().use { check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)) }
        val uri = FileProvider.getUriForFile(application, "${application.packageName}.fileprovider", file)
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "image/png"
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newRawUri("Listening position", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        context.startActivity(Intent.createChooser(intent, "Share listening position"))
    }
}
