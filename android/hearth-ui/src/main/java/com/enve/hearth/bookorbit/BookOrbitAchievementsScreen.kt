package com.enve.hearth.bookorbit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.engine.bookorbit.BookOrbitAchievement
import com.enve.engine.bookorbit.BookOrbitAchievements
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.hearthDisplay
import java.text.DateFormat
import java.util.Date

@Composable
fun BookOrbitAchievementsScreen(onBack: () -> Unit) {
    val vm: BookOrbitAchievementsViewModel = hiltViewModel()
    val accounts by vm.accounts.collectAsStateWithLifecycle()
    val accountId by vm.activeAccountId.collectAsStateWithLifecycle()
    val earnedOnly by vm.showEarnedOnly.collectAsStateWithLifecycle()
    val state by vm.state.collectAsStateWithLifecycle()

    BookOrbitScreen(
        overline = "BookOrbit",
        title = "Achievements",
        accounts = accounts,
        selectedAccountId = accountId,
        onSelectAccount = vm::selectAccount,
        onBack = onBack,
    ) {
        when (val current = state) {
            BookOrbitLoad.Loading -> BookOrbitLoadingBlock()
            BookOrbitLoad.NoAccount -> BookOrbitPlaceholder(
                headline = "No BookOrbit account",
                body = "Add a BookOrbit source to collect achievements as you read.",
            )
            BookOrbitLoad.Unavailable -> BookOrbitPlaceholder(
                headline = "No achievements here",
                body = "This BookOrbit server runs a build without the achievement catalogue.",
                onRetry = vm::retry,
            )
            BookOrbitLoad.Failed -> BookOrbitPlaceholder(
                headline = "Couldn't reach BookOrbit",
                body = "The server didn't answer. Check that the source is online and try again.",
                onRetry = vm::retry,
            )
            is BookOrbitLoad.Ready -> AchievementList(
                catalogue = current.value,
                earnedOnly = earnedOnly,
                modifier = Modifier.weight(1f),
                onEarnedOnlyChange = vm::setEarnedOnly,
            )
        }
    }
}

@Composable
private fun AchievementList(
    catalogue: BookOrbitAchievements,
    earnedOnly: Boolean,
    modifier: Modifier,
    onEarnedOnlyChange: (Boolean) -> Unit,
) {
    val palette = Hearth.palette
    LazyColumn(
        modifier = modifier.fillMaxSize(),
        contentPadding = PaddingValues(
            start = Hearth.Spacing.XL,
            top = Hearth.Spacing.M,
            end = Hearth.Spacing.XL,
            bottom = Hearth.Spacing.XXL,
        ),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XL),
    ) {
        item {
            BookOrbitCard("Collected") {
                Text(
                    "${catalogue.totalEarned} of ${catalogue.totalAvailable}",
                    style = hearthDisplay(36.sp, FontWeight.SemiBold),
                    color = palette.text,
                )
                BookOrbitBar(
                    label = "Catalogue complete",
                    value = "${percent(catalogue.totalEarned, catalogue.totalAvailable)}%",
                    fraction = catalogue.totalEarned.toFloat() / catalogue.totalAvailable.coerceAtLeast(1).toFloat(),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
                    HearthChip("All", !earnedOnly, onClick = { onEarnedOnlyChange(false) })
                    HearthChip("Earned", earnedOnly, onClick = { onEarnedOnlyChange(true) })
                }
            }
        }

        catalogue.categories.forEach { category ->
            val visible = if (earnedOnly) category.achievements.filter { it.earned } else category.achievements
            if (visible.isEmpty()) return@forEach
            item(key = category.key) {
                BookOrbitCard(
                    category.label,
                    caption = "${category.earnedCount} of ${category.totalCount} earned",
                ) {
                    visible.forEach { achievement ->
                        AchievementRow(achievement)
                    }
                }
            }
        }

        if (earnedOnly && catalogue.totalEarned == 0) {
            item {
                BookOrbitPlaceholder(
                    headline = "Nothing earned yet",
                    body = "Keep reading — BookOrbit awards these as your history grows.",
                )
            }
        }
    }
}

@Composable
private fun AchievementRow(achievement: BookOrbitAchievement) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    Row(
        Modifier.fillMaxWidth().padding(vertical = Hearth.Spacing.XS),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Box(
            Modifier
                .size(34.dp)
                .clip(CircleShape)
                .background(if (achievement.earned && !eink.active) palette.ember.copy(alpha = 0.18f) else palette.bg)
                .border(1.dp, palette.hairline, CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                if (achievement.earned) Icons.Filled.CheckCircle else Icons.Outlined.Lock,
                contentDescription = null,
                tint = if (achievement.earned) palette.ember else palette.textTertiary,
                modifier = Modifier.size(18.dp),
            )
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
            Text(
                achievement.name,
                style = HearthText.Label,
                color = if (achievement.earned) palette.text else palette.textSecondary,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                achievement.description,
                style = HearthText.Caption,
                color = palette.textTertiary,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            val threshold = achievement.threshold
            val progress = achievement.currentProgress
            when {
                achievement.earned -> achievement.awardedAtMs?.let {
                    Text(
                        "Earned ${DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date(it))}",
                        style = HearthText.Caption,
                        color = palette.textTertiary,
                    )
                }
                threshold != null && progress != null -> BookOrbitBar(
                    label = "Progress",
                    value = "${progress.toInt()} / ${threshold.toInt()}",
                    fraction = (progress / threshold.coerceAtLeast(1.0)).toFloat(),
                )
            }
        }
    }
}

private fun percent(earned: Int, total: Int): Int =
    ((earned.toFloat() / total.coerceAtLeast(1).toFloat()) * 100f).toInt().coerceIn(0, 100)
