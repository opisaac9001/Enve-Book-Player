package com.enve.hearth.detail

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.engine.library.LibraryDownloadState
import com.enve.engine.library.LibraryDownloadStatus
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import kotlin.math.roundToInt

@Composable
internal fun PersonalRatingSection(
    rating: Int?,
    sourceName: String,
    updating: Boolean,
    onRate: (Int) -> Unit,
) {
    val palette = Hearth.palette
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Hearth.Spacing.XL)
            .padding(top = Hearth.Spacing.L)
            .clip(RoundedCornerShape(Hearth.Radius.Card))
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card))
            .padding(Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Overline("Your rating")
        Row(verticalAlignment = Alignment.CenterVertically) {
            (1..5).forEach { value ->
                Box(
                    Modifier
                        .size(48.dp)
                        .clip(CircleShape)
                        .clickable(enabled = !updating, role = Role.Button) { onRate(value) }
                        .semantics { contentDescription = "$value star${if (value == 1) "" else "s"}" },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        imageVector = if (value <= (rating ?: 0)) Icons.Filled.Star else Icons.Outlined.Star,
                        contentDescription = null,
                        tint = if (value <= (rating ?: 0)) palette.ember else palette.textTertiary,
                        modifier = Modifier.size(26.dp),
                    )
                }
            }
            if (updating) {
                CircularProgressIndicator(
                    modifier = Modifier.size(18.dp),
                    strokeWidth = 2.dp,
                    color = palette.ember,
                )
            }
        }
        Text(
            if (rating == null) "Choose 1-5 stars. This saves to $sourceName."
            else "$rating of 5 · Saved with $sourceName",
            style = HearthText.Caption,
            color = palette.textSecondary,
        )
    }
}

@Composable
internal fun DownloadStatusPill(
    book: Book,
    state: LibraryDownloadState,
    onClick: () -> Unit,
    formatLabel: String? = null,
    modifier: Modifier = Modifier,
) {
    if (book.source == BookSource.LOCAL) return
    val palette = Hearth.palette
    val shape = RoundedCornerShape(999.dp)
    val progress by animateFloatAsState(
        targetValue = state.progress.coerceIn(0f, 1f),
        animationSpec = tween(250),
        label = "detail_download_progress",
    )
    val label = downloadLabel(book, state, progress, formatLabel)
    Row(
        modifier
            .height(52.dp)
            .widthIn(min = 148.dp)
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 18.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        DownloadGlyph(book = book, state = state, progress = progress)
        Spacer(Modifier.width(7.dp))
        Text(
            label,
            style = HearthText.Label.copy(fontWeight = FontWeight.Medium),
            color = palette.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
internal fun FinishedStatusPill(
    finished: Boolean,
    onClick: () -> Unit,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(999.dp)
    Row(
        Modifier.height(52.dp)
            .widthIn(min = 118.dp)
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            if (finished) "✓" else "○",
            style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold),
            color = if (finished) palette.ember else palette.textSecondary,
        )
        Spacer(Modifier.width(7.dp))
        Text(
            if (finished) "Finished" else "Mark\nfinished",
            style = HearthText.Label.copy(fontWeight = FontWeight.Medium),
            color = palette.text,
            maxLines = 2,
            textAlign = TextAlign.Center,
            lineHeight = 16.sp,
        )
    }
}

@Composable
private fun DownloadGlyph(book: Book, state: LibraryDownloadState, progress: Float) {
    val palette = Hearth.palette
    when {
        book.isDownloaded || state.status == LibraryDownloadStatus.COMPLETED -> {
            Text("✓", style = HearthText.Label, color = palette.ember)
        }
        state.isActive -> {
            Canvas(Modifier.size(15.dp)) {
                val stroke = 2.5.dp.toPx()
                drawCircle(color = palette.hairline, style = Stroke(stroke))
                drawArc(
                    color = palette.ember,
                    startAngle = -90f,
                    sweepAngle = 360f * progress.coerceAtLeast(0.02f),
                    useCenter = false,
                    style = Stroke(width = stroke, cap = StrokeCap.Round),
                )
            }
        }
        state.status == LibraryDownloadStatus.FAILED || state.status == LibraryDownloadStatus.CANCELLED -> {
            Text("↻", style = HearthText.Label, color = palette.text)
        }
        else -> Text("↓", style = HearthText.Label, color = palette.text)
    }
}

private fun downloadLabel(book: Book, state: LibraryDownloadState, progress: Float, formatLabel: String? = null): String =
    when {
        book.isDownloaded || state.status == LibraryDownloadStatus.COMPLETED -> if (formatLabel == null) "Downloaded" else "${formatLabel.replaceFirstChar(Char::uppercaseChar)} downloaded"
        state.status == LibraryDownloadStatus.QUEUED -> if (formatLabel == null) "Queued" else "${formatLabel.replaceFirstChar(Char::uppercaseChar)} queued"
        state.status == LibraryDownloadStatus.DOWNLOADING -> if (formatLabel == null) "${(progress * 100).roundToInt()}%" else "$formatLabel ${(progress * 100).roundToInt()}%"
        state.status == LibraryDownloadStatus.FAILED || state.status == LibraryDownloadStatus.CANCELLED -> if (formatLabel == null) "Try again" else "Retry $formatLabel"
        else -> if (formatLabel == null) "Download" else "Download $formatLabel"
    }

internal enum class AnnotationFilter(val label: String) {
    ALL("All"),
    BOOKMARKS("Bookmarks"),
    HIGHLIGHTS("Highlights"),
    NOTES("Notes"),
}
