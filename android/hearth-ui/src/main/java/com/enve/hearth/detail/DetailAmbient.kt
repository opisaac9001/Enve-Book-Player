package com.enve.hearth.detail

import android.graphics.Bitmap
import android.graphics.Color as AndroidColor
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import androidx.core.graphics.drawable.toBitmap
import coil.imageLoader
import coil.request.ImageRequest
import coil.request.SuccessResult
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.LocalHearthImageLoader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

@Composable
internal fun rememberDetailAmbientColor(coverUrl: String?, fallback: Color): Color {
    val context = LocalContext.current
    val sharedLoader = LocalHearthImageLoader.current
    var color by remember(coverUrl, fallback) { mutableStateOf(fallback) }

    LaunchedEffect(coverUrl, fallback, sharedLoader) {
        val url = coverUrl?.takeIf { it.isNotBlank() }
        if (url == null) {
            color = fallback
            return@LaunchedEffect
        }

        val request = ImageRequest.Builder(context)
            .data(url)
            .allowHardware(false)
            .size(96, 144)
            .build()
        val result = runCatching { (sharedLoader ?: context.imageLoader).execute(request) }.getOrNull()
        val drawable = (result as? SuccessResult)?.drawable
        color = if (drawable == null) {
            fallback
        } else {
            withContext(Dispatchers.Default) {
                drawable.toBitmap(width = 72, height = 108, config = Bitmap.Config.ARGB_8888)
                    .coverAmbientColor()
            } ?: fallback
        }
    }

    return color
}

private fun Bitmap.coverAmbientColor(): Color? {
    var weightedRed = 0f
    var weightedGreen = 0f
    var weightedBlue = 0f
    var totalWeight = 0f
    val stepX = (width / 28).coerceAtLeast(1)
    val stepY = (height / 28).coerceAtLeast(1)

    for (y in stepY / 2 until height step stepY) {
        for (x in stepX / 2 until width step stepX) {
            val pixel = getPixel(x, y)
            if (AndroidColor.alpha(pixel) < 200) continue

            val red = AndroidColor.red(pixel)
            val green = AndroidColor.green(pixel)
            val blue = AndroidColor.blue(pixel)
            val max = maxOf(red, green, blue)
            val min = minOf(red, green, blue)
            val brightness = max / 255f
            val saturation = if (max == 0) 0f else (max - min) / max.toFloat()
            if (brightness < 0.08f || brightness > 0.95f || saturation < 0.06f) continue

            val weight = (0.18f + saturation) * brightness
            weightedRed += red * weight
            weightedGreen += green * weight
            weightedBlue += blue * weight
            totalWeight += weight
        }
    }

    if (totalWeight <= 0f) return null
    val red = (weightedRed / totalWeight).roundToInt().coerceIn(0, 255)
    val green = (weightedGreen / totalWeight).roundToInt().coerceIn(0, 255)
    val blue = (weightedBlue / totalWeight).roundToInt().coerceIn(0, 255)
    return tunedAmbientColor(red, green, blue)
}

private fun tunedAmbientColor(red: Int, green: Int, blue: Int): Color {
    val hsv = FloatArray(3)
    AndroidColor.RGBToHSV(red, green, blue, hsv)
    hsv[1] = hsv[1].coerceIn(0.24f, 0.72f)
    hsv[2] = (hsv[2] * 0.62f).coerceIn(0.22f, 0.46f)
    return Color(AndroidColor.HSVToColor(hsv))
}

@Composable
internal fun DetailAmbientWash(color: Color) {
    if (Hearth.eink.suppressGradients) return

    Box(
        Modifier.fillMaxWidth()
            .height(640.dp)
            .background(
                Brush.verticalGradient(
                    colorStops = arrayOf(
                        0.00f to color.copy(alpha = 0.30f),
                        0.36f to color.copy(alpha = 0.20f),
                        0.68f to color.copy(alpha = 0.08f),
                        1.00f to Color.Transparent,
                    ),
                ),
            ),
    )
}
