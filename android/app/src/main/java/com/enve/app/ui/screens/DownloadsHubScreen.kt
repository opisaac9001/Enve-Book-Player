package com.enve.app.ui.screens

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.enve.app.R
import com.enve.app.data.offline.OfflineDownloadProgress
import com.enve.app.data.offline.OfflineDownloadStatus
import com.enve.app.ui.components.*
import com.enve.app.ui.components.ScreenBackButton
import com.enve.app.ui.theme.DS
import com.enve.app.ui.theme.EnveTheme
import com.enve.app.ui.theme.eink
import com.enve.app.ui.theme.einkAwareBackground
import com.enve.app.ui.theme.rememberAdaptiveMetrics
import com.enve.app.ui.theme.scaled
import com.enve.app.viewmodel.DownloadsHubState
import com.enve.core.data.local.KeepNextOfflineSettings
import com.enve.hearth.design.hearthDisplay

@Composable
fun DownloadsHubScreen(
    state: DownloadsHubState,
    onRefresh: () -> Unit,
    onBack: () -> Unit,
    onRemoveItem: (String) -> Unit = {},
    onCancelDownload: (String) -> Unit = {},
    onRetryDownload: (String) -> Unit = {},
    autoDeleteFinishedBooks: Boolean = false,
    autoDeleteFailedDownloads: Boolean = true,
    seriesPreDownloadCount: Int = 5,
    keepNextOfflineEnabled: Boolean = false,
    keepNextOfflineCount: Int = 1,
    onAutoDeleteFinishedBooksChange: (Boolean) -> Unit = {},
    onAutoDeleteFailedDownloadsChange: (Boolean) -> Unit = {},
    onSeriesPreDownloadCountChange: (Int) -> Unit = {},
    onKeepNextOfflineEnabledChange: (Boolean) -> Unit = {},
    onKeepNextOfflineCountChange: (Int) -> Unit = {},
    onDownloadOnCellularChange: (Boolean) -> Unit = {},
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val hPad = DS.Spacing.LG.scaled(metrics)
    val itemGap = DS.Spacing.MD.scaled(metrics)

    SettingsScreenLayout(animatedBackground = true) {

        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding(),
            contentPadding = PaddingValues(bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(itemGap),
        ) {
            item(key = "header") {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = hPad, vertical = DS.Spacing.SM.scaled(metrics)),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    ScreenBackButton(onClick = onBack)

                    Text(
                        text = "Downloads",
                        color = colors.primaryText,
                        style = hearthDisplay(22.sp),
                        modifier = Modifier
                            .weight(1f)
                            .padding(start = itemGap),
                    )

                    IconButton(
                        onClick = onRefresh,
                        modifier = Modifier.background(colors.cardBackground.copy(alpha = 0.8f), CircleShape),
                    ) {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh", tint = colors.primaryText)
                    }
                }
            }

            item(key = "policy-card") {
                DownloadPolicyCard(
                    downloadOnCellular = state.downloadOnCellular,
                    autoDeleteFinishedBooks = autoDeleteFinishedBooks,
                    autoDeleteFailedDownloads = autoDeleteFailedDownloads,
                    seriesPreDownloadCount = seriesPreDownloadCount,
                    keepNextOfflineEnabled = keepNextOfflineEnabled,
                    keepNextOfflineCount = keepNextOfflineCount,
                    onDownloadOnCellularChange = onDownloadOnCellularChange,
                    onAutoDeleteFinishedBooksChange = onAutoDeleteFinishedBooksChange,
                    onAutoDeleteFailedDownloadsChange = onAutoDeleteFailedDownloadsChange,
                    onSeriesPreDownloadCountChange = onSeriesPreDownloadCountChange,
                    onKeepNextOfflineEnabledChange = onKeepNextOfflineEnabledChange,
                    onKeepNextOfflineCountChange = onKeepNextOfflineCountChange,
                    modifier = Modifier.padding(horizontal = hPad),
                )
            }

            when {
                state.isLoading -> {
                    items(4, key = { "skeleton-$it" }) {
                        BookRowSkeleton(modifier = Modifier.padding(horizontal = hPad))
                    }
                }

                state.downloadedBooks.isEmpty() && state.activeDownloads.isEmpty() && state.terminalDownloads.isEmpty() -> {
                    item(key = "empty") {
                        EmptyDownloadsState(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(horizontal = hPad),
                        )
                    }
                }

                else -> {
                    if (state.activeDownloads.isNotEmpty()) {
                        item(key = "active-header") {
                            Box(modifier = Modifier.padding(horizontal = hPad)) {
                                SectionHeaderRow(
                                    icon = Icons.Default.Downloading,
                                    title = "Active Downloads",
                                    count = state.activeDownloads.size,
                                )
                            }
                        }

                        items(state.activeDownloads, key = { "active-${it.bookId}" }) { download ->
                            ActiveDownloadCard(
                                download = download,
                                onCancel = { onCancelDownload(download.bookId) },
                                modifier = Modifier.padding(horizontal = hPad),
                            )
                        }
                    }

                    if (state.terminalDownloads.isNotEmpty()) {
                        item(key = "terminal-header") {
                            Box(modifier = Modifier.padding(horizontal = hPad)) {
                                SectionHeaderRow(
                                    icon = Icons.Default.ReportProblem,
                                    title = "Needs Attention",
                                    count = state.terminalDownloads.size,
                                )
                            }
                        }

                        items(state.terminalDownloads, key = { "terminal-${it.bookId}" }) { download ->
                            TerminalDownloadCard(
                                download = download,
                                onRetry = { onRetryDownload(download.bookId) },
                                onRemove = { onRemoveItem(download.bookId) },
                                modifier = Modifier.padding(horizontal = hPad),
                            )
                        }
                    }

                    if (state.downloadedBooks.isNotEmpty()) {
                        item(key = "downloaded-header") {
                            Box(modifier = Modifier.padding(horizontal = hPad)) {
                                SectionHeaderRow(
                                    icon = Icons.Default.DownloadDone,
                                    title = "Downloaded",
                                    count = state.downloadedBooks.size,
                                )
                            }
                        }

                        items(state.downloadedBooks.take(50), key = { it.uniqueKey }) { book ->
                            DownloadedBookCard(
                                book = book,
                                onRemove = { onRemoveItem(book.id) },
                                modifier = Modifier.padding(horizontal = hPad),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun DownloadPolicyCard(
    downloadOnCellular: Boolean,
    autoDeleteFinishedBooks: Boolean,
    autoDeleteFailedDownloads: Boolean,
    seriesPreDownloadCount: Int,
    keepNextOfflineEnabled: Boolean,
    keepNextOfflineCount: Int,
    onDownloadOnCellularChange: (Boolean) -> Unit,
    onAutoDeleteFinishedBooksChange: (Boolean) -> Unit,
    onAutoDeleteFailedDownloadsChange: (Boolean) -> Unit,
    onSeriesPreDownloadCountChange: (Int) -> Unit,
    onKeepNextOfflineEnabledChange: (Boolean) -> Unit,
    onKeepNextOfflineCountChange: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.3f)

    SettingsCard(modifier = modifier) {
        SettingsSectionHeader(
            title = "Download Policy",
            subtitle = "Network access, automatic offline, and cleanup rules.",
        )

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    stringResource(R.string.settings_download_on_cellular_title),
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Body.scaled(metrics),
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    stringResource(R.string.settings_download_on_cellular_summary),
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
            Switch(
                checked = downloadOnCellular,
                onCheckedChange = onDownloadOnCellularChange,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = colors.onAccent,
                    checkedTrackColor = colors.accent,
                ),
            )
        }
        HorizontalDivider(color = dividerColor)

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "Keep next items offline",
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Body.scaled(metrics),
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    "Automatically download what comes next in a started audiobook series.",
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
            Switch(
                checked = keepNextOfflineEnabled,
                onCheckedChange = onKeepNextOfflineEnabledChange,
                modifier = Modifier.semantics { contentDescription = "Keep next items offline" },
                colors = SwitchDefaults.colors(
                    checkedThumbColor = colors.onAccent,
                    checkedTrackColor = colors.accent,
                ),
            )
        }

        if (keepNextOfflineEnabled) {
            HorizontalDivider(color = dividerColor)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        "Items to keep",
                        color = colors.primaryText,
                        fontSize = DS.FontSize.Body.scaled(metrics),
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        "Runs when the current book is downloaded. Cellular use follows the setting above.",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                }
                val counts = KeepNextOfflineSettings.ALLOWED_COUNTS
                val countIndex = counts.indexOf(keepNextOfflineCount).coerceAtLeast(0)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(
                        onClick = {
                            counts.getOrNull(countIndex - 1)?.let(onKeepNextOfflineCountChange)
                        },
                        enabled = countIndex > 0,
                    ) {
                        Icon(
                            Icons.Default.Remove,
                            contentDescription = "Keep fewer items offline",
                            tint = colors.accent,
                        )
                    }
                    Text(
                        text = keepNextOfflineCount.toString(),
                        color = colors.primaryText,
                        fontSize = DS.FontSize.Headline.scaled(metrics),
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(horizontal = 8.dp),
                    )
                    IconButton(
                        onClick = {
                            counts.getOrNull(countIndex + 1)?.let(onKeepNextOfflineCountChange)
                        },
                        enabled = countIndex < counts.lastIndex,
                    ) {
                        Icon(
                            Icons.Default.Add,
                            contentDescription = "Keep more items offline",
                            tint = colors.accent,
                        )
                    }
                }
            }
        }
        HorizontalDivider(color = dividerColor)

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "Auto-delete finished books",
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Body.scaled(metrics),
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    "Remove the local copy when a book is marked complete.",
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
            Switch(
                checked = autoDeleteFinishedBooks,
                onCheckedChange = onAutoDeleteFinishedBooksChange,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = colors.onAccent,
                    checkedTrackColor = colors.accent,
                ),
            )
        }
        HorizontalDivider(color = dividerColor)

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "Clean up failed downloads",
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Body.scaled(metrics),
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    "Remove canceled or errored downloads on app start.",
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
            Switch(
                checked = autoDeleteFailedDownloads,
                onCheckedChange = onAutoDeleteFailedDownloadsChange,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = colors.onAccent,
                    checkedTrackColor = colors.accent,
                ),
            )
        }
        HorizontalDivider(color = dividerColor)

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "Save next in series",
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Body.scaled(metrics),
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    "How many books the \"Save Next Offline\" menu action queues at once. Comics & graphic novels via Komga.",
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton(
                    onClick = { onSeriesPreDownloadCountChange((seriesPreDownloadCount - 1).coerceAtLeast(1)) },
                    enabled = seriesPreDownloadCount > 1,
                ) {
                    Icon(Icons.Default.Remove, contentDescription = "Decrease", tint = colors.accent)
                }
                Text(
                    text = seriesPreDownloadCount.toString(),
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Headline.scaled(metrics),
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(horizontal = 8.dp),
                )
                IconButton(
                    onClick = { onSeriesPreDownloadCountChange((seriesPreDownloadCount + 1).coerceAtMost(25)) },
                    enabled = seriesPreDownloadCount < 25,
                ) {
                    Icon(Icons.Default.Add, contentDescription = "Increase", tint = colors.accent)
                }
            }
        }
    }
}

@Composable
private fun SectionHeaderRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    count: Int,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = null,
            tint = colors.accent,
            modifier = Modifier.size(18.dp.scaled(metrics)),
        )
        Text(
            text = title.uppercase(),
            color = colors.tertiaryText,
            fontSize = 11.sp,
            fontWeight = FontWeight.SemiBold,
            letterSpacing = 1.6.sp,
        )
        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(999.dp))
                .background(colors.accent.copy(alpha = 0.15f))
                .padding(horizontal = 8.dp, vertical = 2.dp),
        ) {
            Text(
                text = count.toString(),
                color = colors.accent,
                fontSize = DS.FontSize.Caption2.scaled(metrics),
                fontWeight = FontWeight.SemiBold,
            )
        }
    }
}

@Composable
private fun ActiveDownloadCard(
    download: OfflineDownloadProgress,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val animatedProgress by animateFloatAsState(
        targetValue = download.progress.coerceIn(0f, 1f),
        animationSpec = tween(300),
        label = "download_progress",
    )

    SettingsCard(modifier = modifier) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DS.Spacing.MD.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        download.title,
                        color = colors.primaryText,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = DS.FontSize.Subheadline.scaled(metrics),
                    )
                    Text(
                        text = "${(animatedProgress * 100).toInt()}% • ${download.completedTracks}/${download.totalTracks} tracks",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                }
                IconButton(onClick = onCancel) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "Cancel download",
                        tint = Color(0xFFB3453E),
                    )
                }
            }
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(6.dp)
                    .clip(RoundedCornerShape(3.dp))
                    .background(colors.separator.copy(alpha = 0.4f)),
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth(animatedProgress)
                        .fillMaxHeight()
                        .clip(RoundedCornerShape(3.dp))
                        .einkAwareBackground(
                            brush = SolidColor(colors.accent),
                            einkFill = colors.primaryText,
                            shape = RoundedCornerShape(3.dp),
                        ),
                )
            }
        }
    }
}

@Composable
private fun TerminalDownloadCard(
    download: OfflineDownloadProgress,
    onRetry: () -> Unit,
    onRemove: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val failed = download.status == OfflineDownloadStatus.FAILED
    val statusLabel = if (failed) "Failed" else "Cancelled"
    val statusColor = if (failed) colors.accent else colors.secondaryText

    SettingsCard(modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DS.Spacing.MD.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
        ) {
            Icon(
                imageVector = if (failed) Icons.Default.ErrorOutline else Icons.Default.Block,
                contentDescription = null,
                tint = statusColor,
                modifier = Modifier.size(24.dp.scaled(metrics)),
            )

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    download.title,
                    color = colors.primaryText,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = DS.FontSize.Subheadline.scaled(metrics),
                    maxLines = 1,
                )
                Text(
                    text = listOfNotNull(statusLabel, download.errorMessage).joinToString(" • "),
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                    maxLines = 2,
                )
            }

            if (failed) {
                TextButton(onClick = onRetry) {
                    Text("Retry", color = colors.accent)
                }
            }
            IconButton(onClick = onRemove) {
                Icon(
                    imageVector = Icons.Default.Delete,
                    contentDescription = "Remove failed download",
                    tint = Color(0xFFB3453E),
                )
            }
        }
    }
}

@Composable
private fun DownloadedBookCard(
    book: com.enve.core.data.model.Book,
    onRemove: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    SettingsCard(modifier = modifier) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DS.Spacing.MD.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
        ) {
            AsyncImage(
                model = book.coverUrl,
                contentDescription = book.title,
                modifier = Modifier
                    .size(56.dp.scaled(metrics))
                    .clip(RoundedCornerShape(DS.Radius.Small)),
                contentScale = ContentScale.Crop,
            )

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    book.title,
                    color = colors.primaryText,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = DS.FontSize.Subheadline.scaled(metrics),
                    maxLines = 1,
                )
                val subtitle = listOfNotNull(book.author, book.narrator).joinToString(" • ")
                if (subtitle.isNotBlank()) {
                    Text(
                        subtitle,
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                        maxLines = 1,
                    )
                }
            }

            IconButton(onClick = onRemove) {
                Icon(
                    imageVector = Icons.Default.Delete,
                    contentDescription = "Remove",
                    tint = Color(0xFFB3453E),
                )
            }
        }
    }
}
