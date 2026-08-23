package com.enve.hearth.design

import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.MenuBook
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import coil.ImageLoader
import coil.compose.AsyncImage
import coil.request.CachePolicy
import coil.request.ImageRequest

val LocalHearthImageLoader = staticCompositionLocalOf<ImageLoader?> { null }

@Composable
fun CoverTile(
    model: Any?,
    modifier: Modifier = Modifier,
    ambient: Color = Hearth.palette.ember,
    contentDescription: String? = null,
    aspect: Float = 2f / 3f,
    progress: Float = 0f,
    isFinished: Boolean = false,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else Hearth.Radius.Cover)
    val statusDescription = when {
        isFinished -> "Finished"
        progress > 0f -> "${(progress.coerceIn(0f, 1f) * 100).toInt()} percent complete"
        else -> null
    }
    val coverDescription = listOfNotNull(contentDescription, statusDescription)
        .joinToString(", ")
        .takeIf(String::isNotEmpty)

    val shaped = modifier
        .aspectRatio(aspect)
        .then(
            if (eink.borderInsteadOfShadow) {
                Modifier.border(1.5.dp, palette.text, shape)
            } else {
                Modifier.shadow(
                    elevation = 14.dp,
                    shape = shape,
                    ambientColor = ambient.copy(alpha = 0.25f),
                    spotColor = ambient.copy(alpha = 0.25f),
                )
            },
        )
        .clip(shape)
        .background(if (eink.active) palette.bgElevated else ambient.copy(alpha = 0.18f))
        .then(if (!eink.active) Modifier.border(1.dp, palette.hairline, shape) else Modifier)
        .then(
            if (coverDescription != null) {
                Modifier.semantics(mergeDescendants = true) {
                    this.contentDescription = coverDescription
                }
            } else {
                Modifier
            },
        )

    Box(shaped, contentAlignment = Alignment.Center) {
        Icon(
            Icons.AutoMirrored.Outlined.MenuBook,
            contentDescription = null,
            tint = palette.textTertiary,
        )
        if (model != null) {
            val loader = LocalHearthImageLoader.current
            val imageModel = rememberCoverImageModel(model)
            if (loader != null) {
                AsyncImage(imageModel, null, loader, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            } else {
                AsyncImage(imageModel, null, modifier = Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
            }
        }
        if (isFinished) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(palette.bg.copy(alpha = if (eink.active) 0.22f else 0.42f)),
            )
            Box(
                Modifier
                    .align(Alignment.TopEnd)
                    .padding(6.dp)
                    .clip(CircleShape)
                    .background(palette.bg)
                    .padding(2.dp),
            ) {
                Icon(
                    Icons.Filled.CheckCircle,
                    contentDescription = null,
                    tint = if (eink.active) palette.text else palette.statusOK,
                    modifier = Modifier.size(28.dp),
                )
            }
        } else if (progress > 0f) {
            Ribbon(
                progress = progress,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .padding(horizontal = 4.dp, vertical = 6.dp),
            )
        }
    }
}

@Composable
fun rememberCoverImageModel(model: Any?): Any? {
    val context = LocalContext.current
    return remember(model, context) {
        val url = (model as? String)?.takeIf { it.isNotBlank() } ?: return@remember model
        val cacheKey = stableCoverCacheKey(url)
        ImageRequest.Builder(context)
            .data(url)
            .memoryCachePolicy(CachePolicy.ENABLED)
            .diskCachePolicy(CachePolicy.ENABLED)
            .networkCachePolicy(CachePolicy.ENABLED)
            .memoryCacheKey(cacheKey)
            .diskCacheKey(cacheKey)
            .build()
    }
}

private fun stableCoverCacheKey(url: String): String {
    val parsed = runCatching { Uri.parse(url) }.getOrNull() ?: return "cover:$url"
    val scheme = parsed.scheme
    val host = parsed.host
    if (scheme.isNullOrBlank() || host.isNullOrBlank()) return "cover:$url"

    val port = parsed.port.takeIf { it != -1 }?.let { ":$it" }.orEmpty()
    val path = parsed.encodedPath.orEmpty()
    val query = parsed.queryParameterNames
        .filterNot { it.lowercase() in COVER_CACHE_KEY_IGNORED_QUERY_PARAMS }
        .sorted()
        .flatMap { name ->
            parsed.getQueryParameters(name).map { value -> "${Uri.encode(name)}=${Uri.encode(value)}" }
        }
        .joinToString("&")
        .takeIf { it.isNotBlank() }
        ?.let { "?$it" }
        .orEmpty()

    return "cover:${scheme.lowercase()}://${host.lowercase()}$port$path$query"
}

private val COVER_CACHE_KEY_IGNORED_QUERY_PARAMS = setOf(
    "token",
    "access_token",
    "auth",
    "authorization",
    "api_key",
    "apikey",
    "key",
    "signature",
    "sig",
    "expires",
    "expiry",
    "x-plex-token",
)
