package com.enve.app.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.hearth.design.hearthDisplay

@Composable
fun SettingsScreenLayout(
    modifier: Modifier = Modifier,
    animatedBackground: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = EnveTheme.colors

    Box(
        modifier = modifier
            .fillMaxSize()
            .background(colors.background),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(bottom = DS.Spacing.LG),
            content = content,
        )
    }
}

@Composable
fun SettingsCard(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val eink = EnveTheme.eink
    val shape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(18.dp)

    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(shape)
            .then(
                if (eink.suppressGradients) {

                    Modifier.border(1.dp, colors.primaryText, shape)
                } else {
                    Modifier
                        .background(colors.cardBackground)
                        .border(0.5.dp, Color.White.copy(alpha = 0.08f), shape)
                }
            )
            .padding(vertical = 3.dp.scaled(metrics)),
        content = content,
    )
}

@Composable
fun SettingsNavigationRow(
    icon: ImageVector,
    iconTint: androidx.compose.ui.graphics.Color = EnveTheme.colors.accent,
    title: String,
    subtitle: String? = null,
    enabled: Boolean = true,
    badge: String? = null,
    onClick: () -> Unit = {},
) {
    val metrics = rememberAdaptiveMetrics()
    SettingsNavigationRow(
        iconTint = iconTint,
        title = title,
        subtitle = subtitle,
        enabled = enabled,
        badge = badge,
        onClick = onClick,
        iconContent = {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = iconTint,
                modifier = Modifier.size(DS.IconSize.Large.scaled(metrics)),
            )
        },
    )
}

@Composable
fun SettingsNavigationRow(
    iconTint: androidx.compose.ui.graphics.Color = EnveTheme.colors.accent,
    title: String,
    subtitle: String? = null,
    enabled: Boolean = true,
    badge: String? = null,
    onClick: () -> Unit = {},
    iconContent: @Composable () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val eink = EnveTheme.eink

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {

        val iconShape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else CircleShape
        Box(
            modifier = Modifier
                .size(DS.Size.SettingsIconCircle.scaled(metrics))
                .clip(iconShape)
                .then(
                    if (eink.suppressGradients) {
                        Modifier.border(1.dp, colors.primaryText, iconShape)
                    } else {
                        Modifier.background(iconTint.copy(alpha = DS.Opacity.Tint))
                    }
                ),
            contentAlignment = Alignment.Center,
        ) {
            iconContent()
        }

        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))

        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = title,
                    color = if (enabled) colors.primaryText else colors.tertiaryText,
                    fontSize = DS.FontSize.Body.scaled(metrics),
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                if (badge != null) {
                    Spacer(Modifier.width(DS.Spacing.SM))
                    val badgeShape = if (eink.sharpCorners) RoundedCornerShape(2.dp) else RoundedCornerShape(DS.Radius.Pill)
                    Box(
                        modifier = Modifier
                            .clip(badgeShape)
                            .then(
                                if (eink.suppressGradients) {
                                    Modifier.border(1.dp, colors.primaryText, badgeShape)
                                } else {
                                    Modifier.background(colors.accent.copy(alpha = 0.15f))
                                }
                            )
                            .padding(horizontal = DS.Spacing.SM.scaled(metrics), vertical = DS.Spacing.XXXS.scaled(metrics)),
                    ) {
                        Text(
                            text = badge,
                            color = if (eink.suppressGradients) colors.primaryText else colors.accent,
                            fontSize = DS.FontSize.Caption2.scaled(metrics),
                            fontWeight = FontWeight.SemiBold,
                        )
                    }
                }
            }
            if (subtitle != null) {
                Text(
                    text = subtitle,
                    color = colors.tertiaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }

        Icon(
            imageVector = Icons.Default.ChevronRight,
            contentDescription = null,
            tint = colors.tertiaryText,
            modifier = Modifier.size(DS.IconSize.Large.scaled(metrics)),
        )
    }
}

@Composable
fun SettingsToggleRow(
    icon: ImageVector,
    iconTint: androidx.compose.ui.graphics.Color = EnveTheme.colors.accent,
    title: String,
    subtitle: String? = null,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {

        Box(
            modifier = Modifier
                .size(DS.Size.SettingsIconCircle.scaled(metrics))
                .clip(CircleShape)
                .background(iconTint.copy(alpha = DS.Opacity.Tint)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = iconTint,
                modifier = Modifier.size(DS.IconSize.Large.scaled(metrics)),
            )
        }

        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))

        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = title,
                color = colors.primaryText,
                fontSize = DS.FontSize.Body.scaled(metrics),
                fontWeight = FontWeight.Medium,
            )
            if (subtitle != null) {
                Text(
                    text = subtitle,
                    color = colors.tertiaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
        }

        Switch(
            checked = checked,
            onCheckedChange = onCheckedChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = colors.onAccent,
                checkedTrackColor = colors.accent,
            ),
        )
    }
}

@Composable
fun SettingsSectionHeader(
    title: String,
    subtitle: String? = null,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Column(modifier = modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics))) {
        Text(
            text = title.uppercase(),
            color = colors.tertiaryText,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.6.sp,
        )
        if (subtitle != null) {
            Text(
                text = subtitle,
                color = colors.tertiaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
        }
    }
}

@Composable
fun SettingsHeroHeader(
    title: String,
    subtitle: String,
    badge: String? = null,
    icon: ImageVector = Icons.Default.Headphones,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val eink = EnveTheme.eink

    Column(modifier = modifier.fillMaxWidth()) {
        Text(
            text = title,
            color = colors.primaryText,
            style = hearthDisplay(30.sp),
        )
        Spacer(Modifier.height(4.dp))
        Text(
            text = subtitle,
            color = colors.secondaryText,
            fontSize = 13.sp,
        )
        badge?.let {
            Spacer(Modifier.height(DS.Spacing.SM.scaled(metrics)))
            val badgeShape = if (eink.sharpCorners) RoundedCornerShape(2.dp) else RoundedCornerShape(999.dp)
            Box(
                modifier = Modifier
                    .clip(badgeShape)
                    .then(
                        if (eink.suppressGradients) {
                            Modifier.border(1.dp, colors.primaryText, badgeShape)
                        } else {
                            Modifier.background(colors.accent.copy(alpha = 0.14f))
                        }
                    )
                    .padding(horizontal = 10.dp, vertical = 4.dp),
            ) {
                Text(
                    text = it,
                    color = if (eink.suppressGradients) colors.primaryText else colors.accent,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
    }
}
