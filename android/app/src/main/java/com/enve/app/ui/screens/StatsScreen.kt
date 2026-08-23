package com.enve.app.ui.screens

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.core.data.model.AppMediaType
import com.enve.app.ui.components.*
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.einkAwareBackground
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.Achievement
import com.enve.app.viewmodel.StatsState
import com.enve.hearth.design.hearthDisplay
import java.util.Locale

private val StatEmber = Color(0xFFF5921A)
private val StatSage = Color(0xFF6F8F6A)
private val StatSlate = Color(0xFF64748B)
private val StatWine = Color(0xFFA05252)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun StatsScreen(
    state: StatsState = StatsState(),
    onMediaTypeChange: (AppMediaType) -> Unit = {},
    onRefresh: () -> Unit = {},
    onBack: (() -> Unit)? = null,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    PullToRefreshBox(
        isRefreshing = state.isLoading,
        onRefresh = onRefresh,
        modifier = Modifier.fillMaxSize(),
    ) {
        Box(modifier = Modifier.fillMaxSize()) {
            if (EnveTheme.dynamicBackgroundEnabled) {
                DynamicEnveBackground(
                    modifier = Modifier.matchParentSize(),
                    animated = true,
                    fullScreen = true,
                )
            } else {
                Box(Modifier.matchParentSize().background(colors.background))
            }

            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .statusBarsPadding()
                    .verticalScroll(rememberScrollState())
                    .padding(top = DS.Spacing.SM),
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.LG, vertical = DS.Spacing.SM),
                    horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (onBack != null) {
                        ScreenBackButton(onClick = onBack)
                    }
                    Text(
                        text = if (onBack != null) {
                            "Stats"
                        } else {
                            when (state.mediaType) {
                                AppMediaType.AUDIOBOOK -> "Audiobook Stats"
                                AppMediaType.EBOOK -> "Reading Stats"
                                AppMediaType.PODCAST -> "Audiobook Stats"
                            }
                        },
                        color = colors.primaryText,
                        style = hearthDisplay(22.sp),
                        maxLines = 1,
                        softWrap = false,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f, fill = false),
                    )
                    MediaTypePills(
                        selectedType = state.mediaType,
                        onTypeSelected = onMediaTypeChange,
                    )
                }

                val error = state.error
                if (error != null) {
                    val mono = EnveTheme.eink.monochrome
                    Text(
                        text = if (mono) "⚠ $error" else error,
                        color = if (mono) colors.primaryText else Color(0xFFB3453E),
                        fontSize = DS.FontSize.Subheadline,
                        modifier = Modifier.padding(horizontal = DS.Spacing.LG),
                    )
                    Spacer(Modifier.height(DS.Spacing.SM))
                }

                if (state.isLoading && state.totalHoursListened <= 0f && state.achievements.isEmpty()) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = DS.Spacing.LG.scaled(metrics)),
                        verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                    ) {
                        HeroSkeleton()
                        repeat(2) { BookRowSkeleton() }
                    }
                }

                Spacer(Modifier.height(DS.Spacing.MD))

                XpHeroCard(
                    level = state.level,
                    xp = state.xp,
                    xpToNext = state.xpToNextLevel,
                    rankTitle = state.rankTitle,
                    streak = state.currentStreak,
                )

                Spacer(Modifier.height(DS.Spacing.XXL))

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.LG),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "OVERVIEW",
                        color = colors.tertiaryText,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        letterSpacing = 1.6.sp,
                    )
                }
                Spacer(Modifier.height(DS.Spacing.MD))
                PremiumStatsGrid(state)

                Spacer(Modifier.height(DS.Spacing.XXL))

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = DS.Spacing.LG),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "ACHIEVEMENTS",
                        color = colors.tertiaryText,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.SemiBold,
                        letterSpacing = 1.6.sp,
                    )
                    val unlocked = state.achievements.count { it.isUnlocked }
                    val total = state.achievements.size
                    if (total > 0) {
                        Text(
                            "$unlocked / $total",
                            color = colors.tertiaryText,
                            fontSize = DS.FontSize.Subheadline,
                        )
                    }
                }
                Spacer(Modifier.height(DS.Spacing.MD))
                PremiumAchievementsSection(state.achievements)

                Spacer(Modifier.height(100.dp))
            }
        }
    }
}

@Composable
private fun XpHeroCard(
    level: Int,
    xp: Int,
    xpToNext: Int,
    rankTitle: String,
    streak: Int,
) {
    val colors = EnveTheme.colors
    val progress = if (xpToNext > 0) (xp.toFloat() / xpToNext).coerceIn(0f, 1f) else 0f
    val accent = colors.accent
    val trackColor = colors.separator

    Box(
        modifier = Modifier
            .padding(horizontal = DS.Spacing.LG)
            .fillMaxWidth()
            .clip(RoundedCornerShape(28.dp))
            .einkAwareBackground(
                brush = SolidColor(colors.cardBackground),
                einkFill = colors.background,
                einkBorder = colors.primaryText,
                shape = RoundedCornerShape(28.dp),
            )
            .border(0.5.dp, colors.separator.copy(alpha = 0.6f), RoundedCornerShape(28.dp))
            .padding(24.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val einkActive = EnveTheme.eink.active
            val einkSolid = EnveTheme.colors.primaryText
            Box(
                modifier = Modifier.size(112.dp),
                contentAlignment = Alignment.Center,
            ) {
                Canvas(modifier = Modifier.size(112.dp)) {
                    val stroke = 9.dp.toPx()
                    val inset = stroke / 2f
                    val arcRect = Size(size.width - stroke, size.height - stroke)
                    val startAngle = 135f
                    val sweepMax = 270f
                    drawArc(
                        color = trackColor,
                        startAngle = startAngle,
                        sweepAngle = sweepMax,
                        useCenter = false,
                        topLeft = Offset(inset, inset),
                        size = arcRect,
                        style = Stroke(width = stroke, cap = StrokeCap.Round),
                    )
                    drawArc(
                        color = if (einkActive) einkSolid else accent,
                        startAngle = startAngle,
                        sweepAngle = sweepMax * progress,
                        useCenter = false,
                        topLeft = Offset(inset, inset),
                        size = arcRect,
                        style = Stroke(width = stroke, cap = StrokeCap.Round),
                    )
                }
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        text = "$level",
                        color = colors.primaryText,
                        style = hearthDisplay(28.sp),
                    )
                    Text(
                        text = "LVL",
                        color = colors.secondaryText,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }

            Spacer(Modifier.width(20.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = rankTitle,
                    color = accent,
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.height(4.dp))
                Text(
                    text = "$xp / $xpToNext XP",
                    color = colors.secondaryText,
                    fontSize = 13.sp,
                )
                Spacer(Modifier.height(12.dp))

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(7.dp)
                        .clip(RoundedCornerShape(4.dp))
                        .background(trackColor),
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth(progress)
                            .height(7.dp)
                            .clip(RoundedCornerShape(4.dp))
                            .einkAwareBackground(
                                brush = SolidColor(accent),
                                einkFill = EnveTheme.colors.primaryText,
                                shape = RoundedCornerShape(4.dp),
                            ),
                    )
                }

                Spacer(Modifier.height(14.dp))

                val mono = EnveTheme.eink.monochrome
                Row(
                    modifier = Modifier
                        .clip(RoundedCornerShape(12.dp))
                        .then(
                            if (mono) {
                                Modifier
                                    .background(colors.secondaryBackground)
                                    .border(1.dp, colors.primaryText, RoundedCornerShape(12.dp))
                            } else {
                                Modifier.background(accent.copy(alpha = 0.14f))
                            }
                        )
                        .padding(horizontal = 12.dp, vertical = 6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Default.LocalFireDepartment,
                        contentDescription = null,
                        tint = if (mono) colors.primaryText else accent,
                        modifier = Modifier.size(15.dp),
                    )
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = if (streak > 0) "$streak day streak" else "Start a streak!",
                        color = if (mono) colors.primaryText else accent,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }
    }
}

private data class PremiumStat(
    val icon: ImageVector,
    val label: String,
    val value: String,
    val accentColor: Color,
)

@Composable
private fun PremiumStatsGrid(state: StatsState) {
    val stats = when (state.mediaType) {
        AppMediaType.AUDIOBOOK -> listOf(
            PremiumStat(Icons.Default.Schedule, "Hours", String.format(Locale.US, "%.1f", state.totalHoursListened), StatEmber),
            PremiumStat(Icons.Default.Headphones, "Sessions", state.totalSessions.toString(), StatSlate),
            PremiumStat(Icons.Default.CheckCircle, "Finished", state.booksFinished.toString(), StatSage),
            PremiumStat(Icons.Default.Person, "Authors", state.uniqueAuthors.toString(), StatWine),
        )
        AppMediaType.EBOOK -> listOf(
            PremiumStat(Icons.Default.Schedule, "Hours Read", String.format(Locale.US, "%.1f", state.totalHoursListened), StatEmber),
            PremiumStat(Icons.AutoMirrored.Filled.MenuBook, "Sessions", state.totalSessions.toString(), StatSlate),
            PremiumStat(Icons.Default.CheckCircle, "Finished", state.booksFinished.toString(), StatSage),
            PremiumStat(Icons.Default.Description, "Pages Read", "0", StatWine),
        )
        AppMediaType.PODCAST -> listOf(
            PremiumStat(Icons.Default.Schedule, "Hours", String.format(Locale.US, "%.1f", state.totalHoursListened), StatEmber),
            PremiumStat(Icons.Default.Headphones, "Sessions", state.totalSessions.toString(), StatSlate),
            PremiumStat(Icons.Default.CheckCircle, "Finished", state.booksFinished.toString(), StatSage),
            PremiumStat(Icons.Default.Person, "Authors", state.uniqueAuthors.toString(), StatWine),
        )
    }

    Column(
        modifier = Modifier.padding(horizontal = DS.Spacing.LG),
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD),
    ) {
        stats.chunked(2).forEach { row ->
            Row(
                modifier = Modifier.fillMaxWidth().height(IntrinsicSize.Max),
                horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD),
            ) {
                row.forEach { stat ->
                    PremiumStatCard(stat = stat, modifier = Modifier.weight(1f).fillMaxHeight())
                }
                if (row.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun PremiumStatCard(
    stat: PremiumStat,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors

    Box(
        modifier = modifier
            .heightIn(min = 120.dp)
            .clip(RoundedCornerShape(24.dp))
            .background(colors.cardBackground)
            .border(0.5.dp, colors.separator.copy(alpha = 0.6f), RoundedCornerShape(24.dp)),
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(16.dp),
            verticalArrangement = Arrangement.SpaceBetween,
        ) {
            Icon(
                imageVector = stat.icon,
                contentDescription = null,
                tint = when {
                    EnveTheme.eink.monochrome -> colors.primaryText
                    EnveTheme.dynamicBackgroundEnabled -> stat.accentColor
                    else -> colors.accent
                },
                modifier = Modifier.size(24.dp),
            )
            Column {
                Text(
                    text = stat.value,
                    color = colors.primaryText,
                    style = hearthDisplay(26.sp),
                )
                Text(
                    text = stat.label,
                    color = colors.secondaryText,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                )
            }
        }
    }
}

@Composable
private fun PremiumAchievementsSection(achievements: List<Achievement>) {
    val colors = EnveTheme.colors

    Column(
        modifier = Modifier.padding(horizontal = DS.Spacing.LG),
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM),
    ) {
        achievements.forEach { achievement ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(20.dp))
                    .background(colors.cardBackground)
                    .border(
                        0.5.dp,
                        if (achievement.isUnlocked)
                            colors.accent.copy(alpha = 0.25f)
                        else
                            colors.separator.copy(alpha = 0.6f),
                        RoundedCornerShape(20.dp),
                    )
                    .padding(DS.Spacing.LG),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .background(
                            if (achievement.isUnlocked)
                                colors.accent.copy(alpha = 0.14f)
                            else
                                colors.secondaryBackground,
                            CircleShape,
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = achievement.icon,
                        fontSize = 22.sp,
                    )
                }
                Spacer(Modifier.width(DS.Spacing.MD))
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = achievement.name,
                        color = if (achievement.isUnlocked) colors.primaryText
                        else colors.tertiaryText,
                        fontSize = DS.FontSize.Body,
                        fontWeight = if (achievement.isUnlocked) FontWeight.SemiBold else FontWeight.Normal,
                    )
                    Text(
                        text = achievement.description,
                        color = colors.tertiaryText,
                        fontSize = DS.FontSize.Caption,
                    )
                }
                Spacer(Modifier.width(DS.Spacing.MD))
                if (achievement.isUnlocked) {
                    val mono = EnveTheme.eink.monochrome
                    Box(
                        modifier = Modifier
                            .size(32.dp)
                            .then(
                                if (mono) {
                                    Modifier
                                        .background(colors.secondaryBackground, CircleShape)
                                        .border(1.dp, colors.primaryText, CircleShape)
                                } else {
                                    Modifier.background(StatSage.copy(alpha = 0.14f), CircleShape)
                                }
                            ),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            imageVector = Icons.Default.CheckCircle,
                            contentDescription = "Unlocked",
                            tint = if (mono) colors.primaryText else StatSage,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                } else {
                    Box(
                        modifier = Modifier.size(32.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        CircularProgressIndicator(
                            progress = { achievement.progress },
                            modifier = Modifier.size(28.dp),
                            color = colors.accent,
                            trackColor = colors.separator,
                            strokeWidth = 3.dp,
                        )
                        Text(
                            text = "${(achievement.progress * 100).toInt()}%",
                            color = colors.tertiaryText,
                            fontSize = 8.sp,
                            fontWeight = FontWeight.Bold,
                        )
                    }
                }
            }
        }
    }
}
