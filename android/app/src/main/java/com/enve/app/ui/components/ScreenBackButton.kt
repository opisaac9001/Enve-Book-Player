package com.enve.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink

@Composable
fun ChromeActionButton(
    onClick: () -> Unit,
    icon: ImageVector,
    contentDescription: String,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val einkActive = EnveTheme.eink.active
    IconButton(
        onClick = onClick,
        modifier = modifier.then(
            if (einkActive) {
                Modifier.border(1.dp, colors.primaryText, RoundedCornerShape(4.dp))
            } else {
                Modifier
                    .background(colors.cardBackground, CircleShape)
                    .border(0.5.dp, colors.separator.copy(alpha = 0.6f), CircleShape)
            }
        ),
    ) {
        Icon(icon, contentDescription = contentDescription, tint = colors.primaryText)
    }
}

@Composable
fun ScreenBackButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    icon: ImageVector = Icons.AutoMirrored.Filled.ArrowBack,
    contentDescription: String = "Back",
) {
    ChromeActionButton(
        onClick = onClick,
        icon = icon,
        contentDescription = contentDescription,
        modifier = modifier,
    )
}
