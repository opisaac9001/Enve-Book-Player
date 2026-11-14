package com.enve.app.ui.screens.reader

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.slideInVertically
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.QuietButton
import com.enve.hearth.design.hearthDisplay
import kotlinx.coroutines.launch

@Composable
internal fun FinishedBookCard(
    title: String,
    onMarkFinished: suspend () -> Boolean,
    onDismiss: () -> Unit,
    onLeave: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val haptics = rememberReaderHaptics()
    val scope = rememberCoroutineScope()
    var visible by remember { mutableStateOf(false) }
    var marked by remember { mutableStateOf(false) }
    var working by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { visible = true }
    val shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else 20.dp)
    AnimatedVisibility(
        visible = visible,
        enter = fadeIn(tween(240)) + slideInVertically(tween(300)) { it / 2 },
        modifier = modifier,
    ) {
        Surface(
            shape = shape,
            color = palette.bgElevated,
            shadowElevation = if (Hearth.eink.active) 0.dp else 12.dp,
            modifier = Modifier.widthIn(max = 360.dp).border(1.dp, palette.ember.copy(alpha = 0.55f), shape),
        ) {
            Column(
                Modifier.padding(horizontal = 20.dp, vertical = 18.dp),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                Text("THE END", style = HearthText.Overline, color = palette.ember)
                Text(
                    title,
                    style = hearthDisplay(20.sp, FontWeight.SemiBold),
                    color = palette.text,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    if (marked) "Marked as finished. Nicely done." else "You've reached the last page.",
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                )
                Row(Modifier.fillMaxWidth().padding(top = Hearth.Spacing.XS), horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    if (!marked) {
                        EmberButton(
                            if (working) "Marking…" else "Mark as finished",
                            onClick = {
                                if (working) return@EmberButton
                                working = true
                                scope.launch {
                                    marked = onMarkFinished()
                                    working = false
                                    if (marked) haptics.confirm()
                                }
                            },
                            modifier = Modifier.weight(1f),
                        )
                    }
                    QuietButton(if (marked) "Back to library" else "Not yet", onClick = if (marked) onLeave else onDismiss, modifier = Modifier.weight(1f))
                }
            }
        }
    }
}
