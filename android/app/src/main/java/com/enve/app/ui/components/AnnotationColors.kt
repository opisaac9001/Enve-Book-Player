package com.enve.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

object AnnotationPalette {
    data class Swatch(val hex: String, val name: String)

    val Yellow = Swatch("#FFF59D", "yellow")
    val Green  = Swatch("#A5D6A7", "green")
    val Blue   = Swatch("#90CAF9", "blue")
    val Pink   = Swatch("#F48FB1", "pink")
    val Orange = Swatch("#FFCC80", "orange")
    val Purple = Swatch("#CE93D8", "purple")

    val All = listOf(Yellow, Green, Blue, Pink, Orange, Purple)

    fun nameFor(hex: String?): String =
        All.firstOrNull { it.hex.equals(hex, ignoreCase = true) }?.name
            ?: hex?.removePrefix("#")?.lowercase()
            ?: "color"
}

@Composable
fun ColorSwatchRow(
    selectedHex: String?,
    onSelect: (String) -> Unit,
    modifier: Modifier = Modifier,
    colors: List<AnnotationPalette.Swatch> = AnnotationPalette.All,
    swatchSize: androidx.compose.ui.unit.Dp = 32.dp,
    contrast: Color = Color.Black,
) {
    Row(
        modifier = modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        colors.forEach { sw ->
            val isSelected = sw.hex.equals(selectedHex, ignoreCase = true)
            val swatchColor = runCatching { Color(android.graphics.Color.parseColor(sw.hex)) }
                .getOrDefault(Color.Yellow)
            val borderColor = if (isSelected) contrast else swatchColor.copy(alpha = 0.5f)
            androidx.compose.foundation.layout.Box(
                modifier = Modifier
                    .size(swatchSize)
                    .clip(CircleShape)
                    .background(swatchColor)
                    .border(width = if (isSelected) 2.dp else 1.dp, color = borderColor, shape = CircleShape)
                    .clickable { onSelect(sw.hex) }
                    .semantics { contentDescription = "${sw.name} color" },
                contentAlignment = Alignment.Center,
            ) {
                if (isSelected) {
                    Icon(Icons.Default.Check, contentDescription = null, tint = contrast,
                         modifier = Modifier.size(swatchSize / 2))
                }
            }
        }
    }
}
