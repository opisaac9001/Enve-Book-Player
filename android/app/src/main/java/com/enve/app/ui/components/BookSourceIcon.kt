package com.enve.app.ui.components

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.Router
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import com.enve.app.R
import com.enve.core.data.model.BookSource
import com.enve.app.ui.theme.EnveTheme

@Composable
@DrawableRes
fun rememberGrimmoryIconRes(): Int {
    val accent = MaterialTheme.colorScheme.primary
    val isDark = EnveTheme.isDark
    return remember(accent, isDark) { GrimmoryAccentMatcher.closestIcon(accent, isDark) }
}

@Composable
@DrawableRes
fun rememberBookSourceIconRes(source: BookSource): Int? = when (source) {
    BookSource.GRIMMORY -> rememberGrimmoryIconRes()
    BookSource.STORYTELLER -> R.drawable.ic_storyteller
    BookSource.AUDIOBOOKSHELF -> R.drawable.ic_audiobookshelf
    BookSource.JELLYFIN -> R.drawable.ic_jellyfin
    BookSource.EMBY -> R.drawable.ic_emby
    BookSource.PLEX -> R.drawable.ic_plex
    BookSource.KOMGA -> R.drawable.ic_komga
    BookSource.KAVITA -> R.drawable.ic_kavita
    BookSource.SILO -> R.drawable.ic_silo
    BookSource.BOOKORBIT -> R.drawable.ic_bookorbit
    BookSource.OPDS -> R.drawable.ic_opds
    BookSource.WEBDAV -> R.drawable.ic_webdav
    BookSource.TORBOX -> R.drawable.ic_torbox
    BookSource.PREMIUMIZE -> R.drawable.ic_premiumize
    BookSource.REALDEBRID -> R.drawable.ic_realdebrid
    else -> null
}

fun BookSource.fallbackIconVector(): ImageVector = when (this) {
    BookSource.SMB -> Icons.Default.Router
    BookSource.LOCAL -> Icons.Default.Folder
    else -> Icons.Default.Language
}

@Composable
fun BookSourceIcon(
    source: BookSource,
    modifier: Modifier = Modifier,
    tint: Color = EnveTheme.colors.accent,
) {
    val res = rememberBookSourceIconRes(source)
    if (res != null) {
        Image(
            painter = painterResource(res),
            contentDescription = null,
            modifier = modifier,
            contentScale = ContentScale.Fit,
        )
    } else {
        Icon(
            imageVector = source.fallbackIconVector(),
            contentDescription = null,
            tint = tint,
            modifier = modifier,
        )
    }
}
