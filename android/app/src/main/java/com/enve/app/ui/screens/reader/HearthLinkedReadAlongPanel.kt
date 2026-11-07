package com.enve.app.ui.screens.reader

import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.enve.hearth.design.Hearth

@Composable
internal fun HearthLinkedReadAlongPanel(
    status: String,
    playing: Boolean,
    following: Boolean,
    finding: Boolean,
    retryable: Boolean,
    onTogglePlayback: () -> Unit,
    onFollow: () -> Unit,
    onListenHere: () -> Unit,
    onRetry: () -> Unit,
    onClose: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    Column(
        modifier.padding(horizontal = Hearth.Spacing.M).fillMaxWidth()
            .background(palette.bgElevated, RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Card))
            .padding(Hearth.Spacing.S),
    ) {
        Text(status, color = palette.textSecondary, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onTogglePlayback) {
                Icon(if (playing) Icons.Filled.Pause else Icons.Filled.PlayArrow,
                    contentDescription = if (playing) "Pause audiobook" else "Play audiobook", tint = palette.text)
            }
            Row(
                Modifier.weight(1f).horizontalScroll(rememberScrollState()),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
            ) {
                TextButton(onClick = onFollow, enabled = !finding) {
                    Text(if (following) "Following audiobook" else "Return to audiobook", color = palette.text)
                }
                if (!following) {
                    TextButton(onClick = onListenHere, enabled = !finding) {
                        Text("Listen from this page", color = palette.text)
                    }
                }
                if (retryable) {
                    TextButton(onClick = onRetry) {
                        Text("Try again", color = palette.ember)
                    }
                }
            }
            IconButton(onClick = onClose) {
                Icon(Icons.Outlined.Close, contentDescription = "Stop following audiobook", tint = palette.text)
            }
        }
    }
}
