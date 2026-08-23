package com.enve.hearth.design

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp

@Composable
fun Overline(text: String, modifier: Modifier = Modifier, color: Color? = null) {
    Text(
        text = text.uppercase(),
        style = HearthText.Overline,
        color = color ?: Hearth.palette.textSecondary,
        modifier = modifier,
    )
}

@Composable
fun EmberButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    leadingIcon: ImageVector? = null,
    tint: Color? = null,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = if (eink.sharpCorners) RoundedCornerShape(0.dp) else RoundedCornerShape(50)
    val fill = tint ?: palette.ember
    Row(
        modifier
            .clip(shape)
            .background(if (eink.active) palette.bg else fill)
            .then(if (eink.active) Modifier.border(2.dp, palette.ember, shape) else Modifier)
            .sizeIn(minHeight = 48.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 24.dp, vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val fg = when {
            eink.active -> palette.ember
            fill.luminance() < 0.52f -> Color(0xFFFFF7EA)
            else -> palette.onEmber
        }
        if (leadingIcon != null) {
            Icon(leadingIcon, contentDescription = null, tint = fg, modifier = Modifier.size(18.dp))
        }
        Text(text, style = HearthText.Label.copy(fontWeight = FontWeight.SemiBold), color = fg)
    }
}

@Composable
fun QuietButton(
    text: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    Row(
        modifier
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .sizeIn(minHeight = 48.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 18.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(text, style = HearthText.Label, color = palette.text)
    }
}

@Composable
fun HearthChip(
    label: String,
    selected: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(50)
    val bg = when {
        selected && eink.active -> palette.bg
        selected -> palette.ember
        else -> palette.bgElevated
    }
    val border = when {
        selected && eink.active -> BorderStroke(2.dp, palette.ember)
        selected -> null
        else -> BorderStroke(1.dp, palette.hairline)
    }
    val fg = when {
        selected && eink.active -> palette.ember
        selected -> palette.readableOnEmber
        else -> palette.textSecondary
    }
    Row(
        modifier
            .clip(shape)
            .background(bg)
            .then(if (border != null) Modifier.border(border, shape) else Modifier)
            .sizeIn(minHeight = 48.dp)
            .semantics { stateDescription = if (selected) "Selected" else "Not selected" }
            .clickable(role = Role.Button, onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = HearthText.Caption.copy(fontWeight = FontWeight.Medium), color = fg)
    }
}

@Composable
fun ShelfHeader(
    title: String,
    modifier: Modifier = Modifier,
    actionLabel: String? = null,
    onAction: (() -> Unit)? = null,
) {
    Row(
        modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Overline(title)
        if (actionLabel != null && onAction != null) {
            Text(
                actionLabel,
                style = HearthText.Caption,
                color = Hearth.palette.ember,
                modifier = Modifier
                    .sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                    .clickable(role = Role.Button, onClick = onAction)
                    .padding(horizontal = Hearth.Spacing.S),
            )
        }
    }
}
