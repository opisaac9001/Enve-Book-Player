package com.enve.hearth.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Remove
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.unit.dp
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthText

val RestReminderMinuteRange = 5..240
private const val REST_REMINDER_STEP = 5

@Composable
fun RestReminderControls(
    enabled: Boolean,
    minutes: Int,
    onEnabledChange: (Boolean) -> Unit,
    onMinutesChange: (Int) -> Unit,
) {
    val palette = Hearth.palette
    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
            Text("Remind me to rest", style = HearthText.Body, color = palette.text)
            Switch(
                checked = enabled,
                onCheckedChange = onEnabledChange,
                colors = SwitchDefaults.colors(checkedTrackColor = palette.ember, checkedThumbColor = palette.readableOnEmber),
            )
        }
        if (enabled) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                Text("Every $minutes minutes", style = HearthText.Label, color = palette.text)
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    StepButton(Icons.Outlined.Remove, "Shorter interval", minutes > RestReminderMinuteRange.first) {
                        onMinutesChange((minutes - REST_REMINDER_STEP).coerceIn(RestReminderMinuteRange))
                    }
                    StepButton(Icons.Outlined.Add, "Longer interval", minutes < RestReminderMinuteRange.last) {
                        onMinutesChange((minutes + REST_REMINDER_STEP).coerceIn(RestReminderMinuteRange))
                    }
                }
            }
        }
        Text(
            "Only time with a book open on screen counts. Leaving the reader pauses the timer, and a break of five minutes or more starts it over.",
            style = HearthText.Caption,
            color = palette.textSecondary,
        )
    }
}

@Composable
private fun StepButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    active: Boolean,
    onClick: () -> Unit,
) {
    val palette = Hearth.palette
    Icon(
        icon,
        contentDescription = label,
        tint = if (active) palette.ember else palette.textSecondary.copy(alpha = 0.4f),
        modifier = Modifier
            .size(40.dp)
            .clip(CircleShape)
            .clickable(enabled = active, onClick = onClick)
            .padding(8.dp),
    )
}
