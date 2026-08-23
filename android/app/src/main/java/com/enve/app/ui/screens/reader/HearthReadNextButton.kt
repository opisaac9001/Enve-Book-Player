package com.enve.app.ui.screens.reader

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.enve.core.data.model.Book
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText

@Composable
internal fun HearthReadNextButton(
    book: Book,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val visible = remember(book.id) { mutableStateOf(false) }
    LaunchedEffect(book.id) { visible.value = true }

    AnimatedVisibility(
        visible = visible.value,
        enter = fadeIn(tween(220)) + slideInVertically(tween(280)) { it / 2 },
        modifier = modifier,
    ) {
        Surface(
            onClick = onClick,
            shape = RoundedCornerShape(20.dp),
            color = palette.bgElevated,
            shadowElevation = if (Hearth.eink.active) 0.dp else 12.dp,
            modifier = Modifier
                .widthIn(max = 360.dp)
                .border(1.dp, palette.ember.copy(alpha = 0.55f), RoundedCornerShape(20.dp)),
        ) {
            Row(
                modifier = Modifier.padding(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                AsyncImage(
                    model = book.coverUrl,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .size(width = 52.dp, height = 76.dp)
                        .clip(RoundedCornerShape(8.dp))
                        .background(palette.bg),
                )
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text("READ NEXT", style = HearthText.Overline, color = palette.ember)
                    Text(
                        book.title,
                        style = HearthText.Body.copy(fontWeight = FontWeight.Bold),
                        color = palette.text,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    val subtitle = book.seriesNumber?.takeIf { it.isNotBlank() }?.let { "Volume $it" }
                        ?: book.author?.takeIf { it.isNotBlank() }
                    subtitle?.let {
                        Text(it, style = HearthText.Caption, color = palette.textSecondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
                Spacer(Modifier.width(10.dp))
                Box(
                    modifier = Modifier
                        .size(36.dp)
                        .clip(CircleShape)
                        .background(palette.ember),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowForward,
                        contentDescription = null,
                        tint = palette.bg,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }
    }
}
