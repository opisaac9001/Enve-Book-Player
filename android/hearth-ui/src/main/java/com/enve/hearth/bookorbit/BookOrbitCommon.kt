package com.enve.hearth.bookorbit

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.engine.bookorbit.BookOrbitAccount
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.Overline
import com.enve.hearth.design.hearthDisplay

sealed interface BookOrbitLoad<out T> {
    data object Loading : BookOrbitLoad<Nothing>
    data object NoAccount : BookOrbitLoad<Nothing>
    data object Unavailable : BookOrbitLoad<Nothing>
    data object Failed : BookOrbitLoad<Nothing>
    data class Ready<T>(val value: T) : BookOrbitLoad<T>
}

internal suspend fun <T : Any> loadBookOrbit(block: suspend () -> T?): BookOrbitLoad<T> = try {
    block()?.let { BookOrbitLoad.Ready(it) } ?: BookOrbitLoad.Unavailable
} catch (e: kotlinx.coroutines.CancellationException) {
    throw e
} catch (_: Exception) {
    BookOrbitLoad.Failed
}

@Composable
fun BookOrbitScreen(
    overline: String,
    title: String,
    accounts: List<BookOrbitAccount>,
    selectedAccountId: String?,
    onSelectAccount: (String) -> Unit,
    onBack: () -> Unit,
    trailing: @Composable () -> Unit = {},
    content: @Composable ColumnScope.() -> Unit,
) {
    val palette = Hearth.palette
    Column(Modifier.fillMaxWidth().fillMaxHeight().background(palette.bg)) {
        Row(
            Modifier
                .fillMaxWidth()
                .statusBarsPadding()
                .padding(Hearth.Spacing.S),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .size(48.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onBack),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.AutoMirrored.Outlined.ArrowBack,
                    contentDescription = "Back",
                    tint = palette.text,
                    modifier = Modifier.size(26.dp),
                )
            }
            Column(Modifier.weight(1f).padding(start = Hearth.Spacing.S)) {
                Overline(overline)
                Text(title, style = HearthText.ScreenTitle, color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            trailing()
        }
        if (accounts.size > 1) {
            LazyRow(
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    horizontal = Hearth.Spacing.XL,
                    vertical = Hearth.Spacing.S,
                ),
                horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            ) {
                items(accounts, key = { it.connectionId }) { account ->
                    HearthChip(
                        label = account.name,
                        selected = account.connectionId == selectedAccountId,
                        onClick = { onSelectAccount(account.connectionId) },
                    )
                }
            }
        }
        content()
    }
}

@Composable
fun BookOrbitPlaceholder(
    headline: String,
    body: String,
    onRetry: (() -> Unit)? = null,
) {
    val palette = Hearth.palette
    Column(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = Hearth.Spacing.XXL, vertical = Hearth.Spacing.XXXL),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Text(headline, style = hearthDisplay(20.sp, FontWeight.SemiBold), color = palette.text, textAlign = TextAlign.Center)
        Text(body, style = HearthText.Body, color = palette.textSecondary, textAlign = TextAlign.Center)
        if (onRetry != null) EmberButton("Try again", onRetry)
    }
}

@Composable
fun BookOrbitLoadingBlock() {
    Box(
        Modifier.fillMaxWidth().padding(vertical = Hearth.Spacing.XXXL),
        contentAlignment = Alignment.Center,
    ) {
        if (Hearth.eink.suppressAnimations) {
            Text("Loading…", style = HearthText.Body, color = Hearth.palette.textSecondary)
        } else {
            CircularProgressIndicator(color = Hearth.palette.ember, modifier = Modifier.size(28.dp))
        }
    }
}

@Composable
fun BookOrbitCard(
    title: String,
    modifier: Modifier = Modifier,
    caption: String? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Card)
    Column(
        modifier
            .fillMaxWidth()
            .clip(shape)
            .background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape)
            .padding(Hearth.Spacing.L),
        verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
            Overline(title)
            if (caption != null) {
                Text(caption, style = HearthText.Caption, color = palette.textTertiary)
            }
        }
        content()
    }
}

@Composable
fun BookOrbitMetric(
    value: String,
    label: String,
    modifier: Modifier = Modifier,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
        Text(
            value,
            style = hearthDisplay(22.sp, FontWeight.SemiBold),
            color = Hearth.palette.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Overline(label)
    }
}

@Composable
fun BookOrbitBar(
    label: String,
    value: String,
    fraction: Float,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else 3.dp)
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.XXS)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text(
                label,
                style = HearthText.Caption,
                color = palette.textSecondary,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(value, style = HearthText.Caption.copy(fontWeight = FontWeight.Medium), color = palette.text)
        }
        Box(
            Modifier
                .fillMaxWidth()
                .height(6.dp)
                .clip(shape)
                .background(if (eink.active) palette.bg else palette.bg)
                .then(if (eink.active) Modifier.border(1.dp, palette.hairline, shape) else Modifier),
        ) {
            Box(
                Modifier
                    .fillMaxWidth(fraction.coerceIn(0f, 1f))
                    .fillMaxHeight()
                    .clip(shape)
                    .background(if (eink.active) palette.text else palette.ember),
            )
        }
    }
}

@Composable
fun BookOrbitColumns(
    values: List<Float>,
    modifier: Modifier = Modifier,
) {
    val palette = Hearth.palette
    val eink = Hearth.eink
    val shape = RoundedCornerShape(if (eink.sharpCorners) 0.dp else 2.dp)
    Row(
        modifier.fillMaxWidth().height(64.dp),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        values.forEach { value ->
            val fraction = value.coerceIn(0f, 1f)
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxHeight(if (fraction <= 0f) 0.03f else 0.12f + 0.88f * fraction)
                    .clip(shape)
                    .background(
                        when {
                            fraction <= 0f -> palette.hairline
                            eink.active -> palette.text
                            else -> palette.ember
                        },
                    ),
            )
        }
    }
}

@Composable
fun BookOrbitDetailRow(label: String, value: String) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, style = HearthText.Caption, color = palette.textSecondary)
        Box(Modifier.weight(1f).width(Hearth.Spacing.S))
        Text(
            value,
            style = HearthText.Caption.copy(fontWeight = FontWeight.Medium),
            color = palette.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f, fill = false),
        )
    }
}

fun formatReadingTime(seconds: Long): String {
    val hours = seconds / 3_600L
    val minutes = (seconds % 3_600L) / 60L
    return when {
        hours > 0L -> "${hours}h ${minutes}m"
        minutes > 0L -> "${minutes}m"
        else -> "0m"
    }
}
