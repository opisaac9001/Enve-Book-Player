package com.enve.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.StickyNote2
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.enve.core.data.model.AnnotationKind
import com.enve.core.data.model.ReaderAnnotation
import java.text.DateFormat
import java.util.Date

@Composable
fun AnnotationCard(
    annotation: ReaderAnnotation,
    bookTitle: String? = null,
    onTap: () -> Unit,
    onMore: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val kind = AnnotationKind.parse(annotation.kind)
    val accent = runCatching { Color(android.graphics.Color.parseColor(annotation.colorHex)) }
        .getOrDefault(Color(0xFFFFF59D))
    val a11y = buildString {
        append(kind.label)
        append(", ")
        append(AnnotationPalette.nameFor(annotation.colorHex))
        if (annotation.selectedText.isNotBlank()) { append(", \"${annotation.selectedText.take(60)}\"") }
        if (!bookTitle.isNullOrBlank()) { append(", in $bookTitle") }
    }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onTap)
            .padding(horizontal = 16.dp, vertical = 12.dp)
            .semantics { contentDescription = a11y },
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier
                .size(width = 4.dp, height = 48.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(accent),
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            when (kind) {
                AnnotationKind.HIGHLIGHT -> {
                    Text(
                        annotation.selectedText.ifBlank { "(no text)" },
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium,
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                AnnotationKind.NOTE -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.AutoMirrored.Filled.StickyNote2, null, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(
                            annotation.note.ifBlank { "Note" },
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium,
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                AnnotationKind.BOOKMARK -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Bookmark, null, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(
                            annotation.selectedText.ifBlank { annotation.note.ifBlank { "Bookmark" } },
                            style = MaterialTheme.typography.bodyMedium,
                            fontWeight = FontWeight.Medium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
            if (kind == AnnotationKind.HIGHLIGHT && annotation.note.isNotBlank()) {
                Text(
                    annotation.note,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (!bookTitle.isNullOrBlank()) {
                    Text(
                        bookTitle,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                val chapterId = annotation.chapterId
                if (!chapterId.isNullOrBlank()) {
                    Text(
                        "·",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        chapterId,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Spacer(Modifier.weight(1f))
                Text(
                    DateFormat.getDateInstance(DateFormat.SHORT).format(Date(annotation.updatedAt)),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        IconButton(onClick = onMore, modifier = Modifier.size(36.dp)) {
            Icon(Icons.Default.MoreVert, contentDescription = "More")
        }
    }
}
