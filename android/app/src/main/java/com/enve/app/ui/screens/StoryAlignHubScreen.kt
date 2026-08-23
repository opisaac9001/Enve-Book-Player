package com.enve.app.ui.screens

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import coil.compose.AsyncImage
import com.enve.hearth.design.hearthDisplay
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
import com.enve.app.viewmodel.StoryAlignHubViewModel
import com.enve.core.data.model.Book

private val HearthRed = Color(0xFFB3453E)

@Composable
fun StoryAlignHubScreen(
    onBack: () -> Unit,
    onConnectStoryteller: () -> Unit,
    onManageServers: () -> Unit,
    onOpenBook: (Book) -> Unit,
    viewModel: StoryAlignHubViewModel = hiltViewModel(),
) {
    val state by viewModel.state.collectAsState()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()

    SettingsScreenLayout(animatedBackground = EnveTheme.dynamicBackgroundEnabled) {
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
                    text = "StoryAlign",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier
                        .weight(1f)
                        .padding(start = DS.Spacing.MD.scaled(metrics)),
                )
                IconButton(onClick = viewModel::refreshLibrary) {
                    if (state.isRefreshing) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(20.dp),
                            strokeWidth = 2.dp,
                            color = colors.accent,
                        )
                    } else {
                        Icon(Icons.Default.Refresh, contentDescription = "Refresh read-aloud library", tint = colors.primaryText)
                    }
                }
            }

            SettingsHeroHeader(
                title = "StoryAlign Hub",
                subtitle = "Read-aloud books with synced EPUB text, audio, and highlighting.",
                badge = "Storyteller read-aloud",
                icon = Icons.Default.RecordVoiceOver,
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            )

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(title = "Status", subtitle = "Storyteller supplies generated read-aloud EPUBs to Android.")
                Row(
                    modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                    horizontalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
                ) {
                    MetricTile(
                        icon = Icons.Default.Dns,
                        label = "Servers",
                        value = state.activeStorytellerConnections.toString(),
                        modifier = Modifier.weight(1f),
                    )
                    MetricTile(
                        icon = Icons.Default.RecordVoiceOver,
                        label = "Read-Aloud",
                        value = state.readyReadAloudBooks.size.toString(),
                        modifier = Modifier.weight(1f),
                    )
                    MetricTile(
                        icon = Icons.Default.AutoStories,
                        label = "Linked",
                        value = state.linkedFormatBooks.size.toString(),
                        modifier = Modifier.weight(1f),
                    )
                }
                state.error?.let { error ->
                    val mono = EnveTheme.eink.monochrome
                    Text(
                        text = if (mono) "⚠ $error" else error,
                        color = if (mono) colors.primaryText else HearthRed,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                        modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                    )
                }
                Row(
                    modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.SM.scaled(metrics)),
                    horizontalArrangement = Arrangement.spacedBy(DS.Spacing.SM.scaled(metrics)),
                ) {
                    Button(
                        onClick = onConnectStoryteller,
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(999.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = Color.White),
                    ) {
                        Icon(Icons.Default.Headphones, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Connect")
                    }
                    OutlinedButton(
                        onClick = onManageServers,
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(999.dp),
                        border = BorderStroke(1.dp, colors.accent),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = colors.accent),
                    ) {
                        Icon(Icons.Default.Dns, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Manage")
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(title = "Ready Read-Aloud Books", subtitle = "Open synced text and audio in the reader.")
                if (state.readyReadAloudBooks.isEmpty()) {
                    EmptyCardText("No ready read-aloud books are cached on this device yet.")
                } else {
                    state.readyReadAloudBooks.forEachIndexed { index, book ->
                        ReadAloudBookRow(book = book, onClick = { onOpenBook(book) })
                        if (index != state.readyReadAloudBooks.lastIndex) {
                            HorizontalDivider(color = colors.separator.copy(alpha = 0.5f))
                        }
                    }
                }
            }

            SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                SettingsSectionHeader(title = "Linked Format Candidates", subtitle = "Books already carrying both ebook and audio formats.")
                if (state.linkedFormatBooks.isEmpty()) {
                    EmptyCardText("No linked ebook/audio books are cached on this device yet.")
                } else {
                    state.linkedFormatBooks.forEachIndexed { index, book ->
                        LinkedBookRow(book = book)
                        if (index != state.linkedFormatBooks.lastIndex) {
                            HorizontalDivider(color = colors.separator.copy(alpha = 0.5f))
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun MetricTile(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    value: String,
    modifier: Modifier = Modifier,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val shape = if (EnveTheme.eink.sharpCorners) RoundedCornerShape(4.dp) else RoundedCornerShape(DS.Radius.Large)
    Column(
        modifier = modifier
            .clip(shape)
            .background(colors.secondaryBackground)
            .border(0.5.dp, colors.separator, shape)
            .padding(DS.Spacing.MD.scaled(metrics)),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(DS.Spacing.XS.scaled(metrics)),
    ) {
        Icon(icon, contentDescription = null, tint = colors.accent, modifier = Modifier.size(22.dp.scaled(metrics)))
        Text(value, color = colors.primaryText, fontSize = DS.FontSize.Title3.scaled(metrics), fontWeight = FontWeight.Bold)
        Text(label, color = colors.secondaryText, fontSize = DS.FontSize.Caption2.scaled(metrics), maxLines = 1)
    }
}

@Composable
private fun ReadAloudBookRow(book: Book, onClick: () -> Unit) {
    BookSummaryRow(
        book = book,
        trailing = {
            Icon(Icons.Default.PlayArrow, contentDescription = "Open read-aloud", tint = EnveTheme.colors.accent)
        },
        onClick = onClick,
    )
}

@Composable
private fun LinkedBookRow(book: Book) {
    BookSummaryRow(
        book = book,
        trailing = {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.AutoStories, contentDescription = "Ebook", tint = EnveTheme.colors.secondaryText, modifier = Modifier.size(18.dp))
                Icon(Icons.Default.Headphones, contentDescription = "Audio", tint = EnveTheme.colors.secondaryText, modifier = Modifier.size(18.dp))
            }
        },
        onClick = null,
    )
}

@Composable
private fun BookSummaryRow(
    book: Book,
    trailing: @Composable () -> Unit,
    onClick: (() -> Unit)?,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val rowModifier = Modifier
        .fillMaxWidth()
        .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
        .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics))
    Row(
        modifier = rowModifier,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AsyncImage(
            model = book.coverUrl,
            contentDescription = book.title,
            contentScale = ContentScale.Crop,
            modifier = Modifier
                .size(width = 42.dp, height = 58.dp)
                .clip(RoundedCornerShape(if (EnveTheme.eink.sharpCorners) 4.dp else 6.dp))
                .background(colors.secondaryBackground),
        )
        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                text = book.title,
                color = colors.primaryText,
                fontSize = DS.FontSize.Body.scaled(metrics),
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = book.author ?: book.narrator ?: book.source.displayName,
                color = colors.secondaryText,
                fontSize = DS.FontSize.Caption.scaled(metrics),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
        trailing()
    }
}

@Composable
private fun EmptyCardText(text: String) {
    val metrics = rememberAdaptiveMetrics()
    Text(
        text = text,
        color = EnveTheme.colors.secondaryText,
        fontSize = DS.FontSize.Caption.scaled(metrics),
        modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
    )
}
