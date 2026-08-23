package com.enve.hearth.design

import android.content.Context
import android.graphics.Bitmap
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import coil.ImageLoader
import coil.imageLoader
import coil.request.ImageRequest
import coil.request.SuccessResult
import com.enve.core.data.model.Book
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.abs

object AmbientColorStore {
    private val cache = ConcurrentHashMap<String, Color>()

    fun cached(key: String?): Color? = key?.let { cache[it] }

    suspend fun resolve(context: Context, loader: ImageLoader, book: Book, fallback: Color): Color {
        cache[book.uniqueKey]?.let { return it }
        val url = book.coverUrl?.takeIf { it.isNotBlank() } ?: return fallback
        val request = ImageRequest.Builder(context).data(url).size(64).allowHardware(false).build()
        val result = loader.execute(request) as? SuccessResult ?: return fallback
        val bitmap = (result.drawable as? android.graphics.drawable.BitmapDrawable)?.bitmap ?: return fallback
        val tint = dominantColor(bitmap)?.warmed() ?: fallback
        cache[book.uniqueKey] = tint
        return tint
    }

    private fun dominantColor(source: Bitmap): Color? {
        val bmp = Bitmap.createScaledBitmap(source, 8, 8, true)
        var bestScore = -1f
        var bestPixel = 0
        var rSum = 0L; var gSum = 0L; var bSum = 0L
        for (y in 0 until 8) for (x in 0 until 8) {
            val p = bmp.getPixel(x, y)
            val r = android.graphics.Color.red(p) / 255f
            val g = android.graphics.Color.green(p) / 255f
            val b = android.graphics.Color.blue(p) / 255f
            rSum += android.graphics.Color.red(p); gSum += android.graphics.Color.green(p); bSum += android.graphics.Color.blue(p)
            val maxC = maxOf(r, g, b)
            val minC = minOf(r, g, b)
            val sat = if (maxC > 0f) (maxC - minC) / maxC else 0f
            val score = sat * (1f - abs(maxC - 0.55f))
            if (score > bestScore) {
                bestScore = score
                bestPixel = p
            }
        }

        if (bestScore < 0.08f) {
            return Color(rSum.toInt() / 64, gSum.toInt() / 64, bSum.toInt() / 64)
        }
        return Color(bestPixel)
    }

    private fun Color.warmed(): Color {
        val hsv = FloatArray(3)
        android.graphics.Color.colorToHSV(toArgb(), hsv)
        hsv[1] = hsv[1].coerceIn(0.25f, 0.85f)
        hsv[2] = hsv[2].coerceIn(0.45f, 0.9f)
        return Color(android.graphics.Color.HSVToColor(hsv))
    }
}

@Composable
fun rememberAmbientTint(book: Book?): Color {
    val palette = Hearth.palette
    if (Hearth.eink.active || book == null) return palette.ember
    val context = LocalContext.current
    val loader = LocalHearthImageLoader.current ?: context.imageLoader
    val tint by produceState(AmbientColorStore.cached(book.uniqueKey) ?: palette.ember, book.uniqueKey) {
        value = AmbientColorStore.resolve(context, loader, book, palette.ember)
    }
    return tint
}
