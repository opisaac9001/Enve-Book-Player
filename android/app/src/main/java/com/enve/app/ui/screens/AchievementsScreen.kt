package com.enve.app.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.EmojiEvents
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.components.SettingsCard
import com.enve.app.ui.components.SettingsHeroHeader
import com.enve.app.ui.components.SettingsScreenLayout
import com.enve.app.ui.components.SettingsSectionHeader
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.Achievement
import com.enve.app.viewmodel.StatsState
import com.enve.hearth.design.hearthDisplay
import java.util.Locale

private val AchieveEmber = Color(0xFFF5921A)
private val AchieveSage = Color(0xFF6F8F6A)

@Composable
fun AchievementsScreen(
    state: StatsState,
    onBack: () -> Unit,
    onRefresh: () -> Unit,
    onWeeklyGoalChange: (Float) -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    SettingsScreenLayout(animatedBackground = true) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .statusBarsPadding()
                .padding(bottom = DS.Spacing.XXL.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.LG.scaled(metrics)),
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ScreenBackButton(onClick = onBack)
                Text(
                    text = "Achievements",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = DS.Spacing.MD.scaled(metrics)),
                )
                IconButton(onClick = onRefresh) {
                    if (state.isLoading) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(20.dp),
                            strokeWidth = 2.dp,
                            color = colors.accent,
                        )
                    } else {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh achievements", tint = colors.primaryText)
                    }
                }
            }

            SettingsHeroHeader(
                title = "Achievements",
                subtitle = "Track streaks, goals, and reading rewards.",
                badge = "${state.achievements.count { it.isUnlocked }} / ${state.achievements.size} unlocked",
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            )

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(title = "Streaks", subtitle = "Keep reading or listening daily to build your streak.")
                Row(
                    modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                    horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                ) {
                    StreakCard(
                        title = "Current",
                        days = state.currentStreak,
                        color = AchieveEmber,
                        modifier = Modifier.weight(1f),
                    )
                    StreakCard(
                        title = "Best",
                        days = state.longestStreak,
                        color = AchieveSage,
                        modifier = Modifier.weight(1f),
                    )
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                val goal = state.weeklyGoalHours.coerceAtLeast(0f)
                val progress = if (goal > 0f) (state.weeklyActivityHours / goal).coerceIn(0f, 1f) else 0f
                SettingsSectionHeader(title = "Weekly Goal", subtitle = "Set a weekly listening and reading target.")
                Column(
                    modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                    verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = if (goal > 0f) {
                                    "${formatHours(state.weeklyActivityHours)} / ${formatHours(goal)} hours"
                                } else {
                                    "No weekly goal set"
                                },
                                color = colors.primaryText,
                                fontSize = DS.FontSize.Headline.scaled(metrics),
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                text = "${(progress * 100).toInt()}% complete",
                                color = colors.secondaryText,
                                fontSize = DS.FontSize.Caption.scaled(metrics),
                            )
                        }
                        Text(
                            text = formatHours(goal),
                            color = colors.accent,
                            fontSize = DS.FontSize.Title3.scaled(metrics),
                            fontWeight = FontWeight.Bold,
                        )
                    }

                    LinearProgressIndicator(
                        progress = { progress },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(8.dp)
                            .clip(RoundedCornerShape(4.dp)),
                        color = colors.accent,
                        trackColor = colors.separator,
                    )

                    Row(horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics))) {
                        OutlinedButton(
                            onClick = { onWeeklyGoalChange((goal - 0.5f).coerceAtLeast(0f)) },
                            enabled = goal > 0f,
                            modifier = Modifier.weight(1f),
                            shape = RoundedCornerShape(999.dp),
                            border = BorderStroke(1.dp, colors.accent),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = colors.accent),
                        ) {
                            Icon(Icons.Default.Remove, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("0.5h")
                        }
                        Button(
                            onClick = { onWeeklyGoalChange((goal + 0.5f).coerceAtMost(168f)) },
                            modifier = Modifier.weight(1f),
                            shape = RoundedCornerShape(999.dp),
                            colors = ButtonDefaults.buttonColors(
                                containerColor = colors.accent,
                                contentColor = colors.onAccent,
                            ),
                        ) {
                            Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("0.5h")
                        }
                        TextButton(
                            onClick = { onWeeklyGoalChange(0f) },
                            enabled = goal > 0f,
                        ) {
                            Text("Clear")
                        }
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(title = "Badges", subtitle = "Unlock badges through time, sessions, and finished books.")
                Column(modifier = Modifier.padding(vertical = DS.Spacing.XS.scaled(metrics))) {
                    state.achievements.forEachIndexed { index, achievement ->
                        AchievementRow(achievement = achievement)
                        if (index != state.achievements.lastIndex) {
                            HorizontalDivider(color = colors.separator.copy(alpha = 0.5f))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun StreakCard(
    title: String,
    days: Int,
    color: Color,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val eink = EnveTheme.eink
    val shape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(DS.Radius.Large)
    val iconShape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else CircleShape
    Column(
        modifier = modifier
            .clip(shape)
            .background(colors.secondaryBackground)
            .border(0.5.dp, colors.separator, shape)
            .padding(DS.Spacing.LG.scaled(metrics)),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
    ) {
        Box(
            modifier = Modifier
                .size(46.dp.scaled(metrics))
                .clip(iconShape)
                .then(
                    if (eink.suppressGradients) {
                        Modifier.border(1.dp, colors.primaryText, iconShape)
                    } else {
                        Modifier.background(color.copy(alpha = 0.14f), iconShape)
                    }
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Default.EmojiEvents,
                contentDescription = null,
                tint = if (eink.monochrome) colors.primaryText else color,
            )
        }
        Text(days.toString(), color = colors.primaryText, style = hearthDisplay(28.sp))
        Text("$title Streak", color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
        Text(if (days == 1) "day" else "days", color = colors.tertiaryText, fontSize = DS.FontSize.Caption2.scaled(metrics))
    }
}

@Composable
private fun AchievementRow(achievement: Achievement) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val eink = EnveTheme.eink
    val iconShape = if (eink.sharpCorners) RoundedCornerShape(4.dp) else CircleShape
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(44.dp.scaled(metrics))
                .clip(iconShape)
                .then(
                    if (eink.suppressGradients) {
                        Modifier.border(1.dp, colors.primaryText, iconShape)
                    } else {
                        Modifier.background(
                            if (achievement.isUnlocked) colors.accent.copy(alpha = 0.14f) else colors.secondaryBackground,
                            iconShape,
                        )
                    }
                ),
            contentAlignment = Alignment.Center,
        ) {
            Text(achievement.icon, fontSize = DS.FontSize.Title3.scaled(metrics))
        }
        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                achievement.name,
                color = if (achievement.isUnlocked) colors.primaryText else colors.tertiaryText,
                fontWeight = FontWeight.SemiBold,
                fontSize = DS.FontSize.Body.scaled(metrics),
            )
            Text(
                achievement.description,
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
            )
        }
        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
        if (achievement.isUnlocked) {
            Icon(
                Icons.Default.CheckCircle,
                contentDescription = "Unlocked",
                tint = if (eink.monochrome) colors.primaryText else AchieveSage,
            )
        } else {
            Box(contentAlignment = Alignment.Center) {
                CircularProgressIndicator(
                    progress = { achievement.progress.coerceIn(0f, 1f) },
                    modifier = Modifier.size(32.dp.scaled(metrics)),
                    color = colors.accent,
                    trackColor = colors.separator,
                    strokeWidth = 3.dp,
                )
                Icon(
                    Icons.Default.Lock,
                    contentDescription = "Locked",
                    tint = colors.tertiaryText,
                    modifier = Modifier.size(14.dp.scaled(metrics)),
                )
            }
        }
    }
}

private fun formatHours(hours: Float): String = String.format(Locale.US, "%.1f", hours.coerceAtLeast(0f))
