package com.enve.hearth.journal

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Remove
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.core.data.local.DailyReadingGoal
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.hearthDisplay
import kotlin.math.roundToInt

@Composable
internal fun ReadingGoalSection(
    progress: DailyGoalProgress,
    onSave: (Int) -> Unit,
    onDisable: () -> Unit,
    modifier: Modifier = Modifier,
) {
    var editing by rememberSaveable { mutableStateOf(false) }

    ReadingGoalCard(progress, onEdit = { editing = true }, modifier = modifier)
    if (editing) {
        ReadingGoalEditor(
            goal = progress.goal,
            onDismiss = { editing = false },
            onSave = {
                onSave(it)
                editing = false
            },
            onDisable = {
                onDisable()
                editing = false
            },
        )
    }
}

@Composable
private fun ReadingGoalCard(
    progress: DailyGoalProgress,
    onEdit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = if (eink.sharpCorners) RectangleShape else RoundedCornerShape(Hearth.Radius.Card)
    val enabled = progress.goal.enabled
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(palette.bgElevated)
            .border(if (eink.active) 1.5.dp else 1.dp, if (eink.active) palette.text else palette.hairline, shape)
            .clickable(
                role = Role.Button,
                onClickLabel = if (enabled) "Edit daily reading goal" else "Set a daily reading goal",
                onClick = onEdit,
            )
            .padding(Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Overline("Daily reading goal")
        if (enabled) {
            Text(
                "${progress.readMinutes} of ${progress.goal.minutes} min",
                style = hearthDisplay(28.sp, FontWeight.SemiBold),
                color = palette.text,
            )
            GoalBar(progress.fraction, progress.complete)
            Text(
                if (progress.complete) "Goal met for today." else "${progress.remainingMinutes} min to go today.",
                style = HearthText.Caption,
                color = palette.textSecondary,
            )
        } else {
            Text(
                "Pick a few minutes of reading to aim for each day.",
                style = HearthText.Body,
                color = palette.textSecondary,
            )
            Text("Set a goal", style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold), color = palette.ember)
        }
    }
}

@Composable
private fun GoalBar(fraction: Float, complete: Boolean) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val track = if (eink.sharpCorners) RectangleShape else RoundedCornerShape(50)
    Box(
        Modifier
            .fillMaxWidth()
            .height(8.dp)
            .clip(track)
            .background(if (eink.active) palette.bg else palette.hairline)
            .then(if (eink.active) Modifier.border(1.dp, palette.text, track) else Modifier)
            .semantics {
                progressBarRangeInfo = ProgressBarRangeInfo(fraction, 0f..1f)
                stateDescription = if (complete) "Goal met" else "${(fraction * 100).roundToInt()} percent"
            },
    ) {
        Box(
            Modifier
                .fillMaxWidth(fraction)
                .fillMaxHeight()
                .clip(track)
                .background(if (eink.active) palette.text else palette.ember),
        )
    }
}

@Composable
private fun ReadingGoalEditor(
    goal: DailyReadingGoal,
    onDismiss: () -> Unit,
    onSave: (Int) -> Unit,
    onDisable: () -> Unit,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    var minutes by rememberSaveable { mutableIntStateOf(goal.minutes) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Daily reading goal", style = HearthText.BookTitle) },
        text = {
            Column(
                Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
            ) {
                Text(
                    "Ebook reading time counts toward this goal. Listening doesn't.",
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                )
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    StepButton(Icons.Outlined.Remove, "Decrease goal", minutes > DailyReadingGoal.MIN_MINUTES) {
                        minutes -= 1
                    }
                    Text(
                        "$minutes min",
                        style = hearthDisplay(28.sp, FontWeight.SemiBold),
                        color = palette.text,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.weight(1f),
                    )
                    StepButton(Icons.Outlined.Add, "Increase goal", minutes < DailyReadingGoal.MAX_MINUTES) {
                        minutes += 1
                    }
                }
                Slider(
                    value = minutes.toFloat(),
                    onValueChange = {
                        minutes = it.roundToInt().coerceIn(DailyReadingGoal.MIN_MINUTES, DailyReadingGoal.MAX_MINUTES)
                    },
                    valueRange = DailyReadingGoal.MIN_MINUTES.toFloat()..DailyReadingGoal.MAX_MINUTES.toFloat(),
                    colors = SliderDefaults.colors(
                        thumbColor = if (eink.active) palette.text else palette.ember,
                        activeTrackColor = if (eink.active) palette.text else palette.ember,
                        inactiveTrackColor = palette.hairline,
                    ),
                    modifier = Modifier.semantics { stateDescription = "$minutes minutes" },
                )
            }
        },
        confirmButton = {
            TextButton(onClick = { onSave(minutes) }) {
                Text("Save", style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold), color = palette.ember)
            }
        },
        dismissButton = {
            Row {
                if (goal.enabled) {
                    TextButton(onClick = onDisable) {
                        Text("Turn off", style = HearthText.Label, color = palette.textSecondary)
                    }
                }
                TextButton(onClick = onDismiss) {
                    Text("Cancel", style = HearthText.Label, color = palette.text)
                }
            }
        },
        containerColor = palette.bgElevated,
        titleContentColor = palette.text,
        textContentColor = palette.textSecondary,
        shape = if (eink.sharpCorners) RectangleShape else RoundedCornerShape(Hearth.Radius.Card),
    )
}

@Composable
private fun StepButton(
    icon: ImageVector,
    label: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    val palette = Hearth.palette
    Box(
        Modifier
            .size(48.dp)
            .clip(CircleShape)
            .border(1.dp, if (enabled) palette.outline else palette.hairline, CircleShape)
            .clickable(enabled = enabled, role = Role.Button, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = label,
            tint = if (enabled) palette.text else palette.textTertiary,
            modifier = Modifier.size(22.dp),
        )
    }
}
