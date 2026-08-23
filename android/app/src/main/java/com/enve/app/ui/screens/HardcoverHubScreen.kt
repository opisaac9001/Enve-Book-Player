package com.enve.app.ui.screens

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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Flag
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.VerifiedUser
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.enve.hearth.design.hearthDisplay
import coil.compose.AsyncImage
import com.enve.app.data.hardcover.HardcoverActivity
import com.enve.app.data.hardcover.HardcoverBookResult
import com.enve.app.data.hardcover.HardcoverLibraryBook
import com.enve.app.data.hardcover.HardcoverUserList
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
import com.enve.app.viewmodel.HardcoverHubViewModel
import kotlin.math.roundToInt

private val HearthRed = Color(0xFFB3453E)

@Composable
fun HardcoverHubScreen(
    onBack: () -> Unit,
) {
    val viewModel: HardcoverHubViewModel = hiltViewModel()
    val state by viewModel.state.collectAsState()
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    val dividerColor = colors.separator.copy(alpha = 0.3f)

    LaunchedEffect(Unit) { viewModel.load() }

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
                    text = "Hardcover",
                    color = colors.primaryText,
                    style = hearthDisplay(22.sp),
                    modifier = Modifier.padding(start = DS.Spacing.MD.scaled(metrics)),
                )
                Spacer(Modifier.weight(1f))
                if (state.hasToken) {
                    TextButton(onClick = viewModel::load, enabled = !state.isLoading) {
                        Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Refresh")
                    }
                }
            }

            SettingsHeroHeader(
                title = "Hardcover Hub",
                subtitle = "Sync goals, lists, library status, and book discovery.",
                icon = Icons.Default.AutoStories,
                modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics)),
            )

            if (!state.hasToken) {
                HardcoverTokenCard(state.tokenInput, state.isSavingToken, viewModel::updateTokenInput, viewModel::saveToken)
            } else {
                HardcoverAccountCard(
                    username = state.profile?.username.orEmpty(),
                    isLoading = state.isLoading,
                    onDisconnect = viewModel::disconnect,
                )

                state.readingGoal?.let { goal ->
                    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                        SettingsSectionHeader(title = "Reading Goal")
                        Column(
                            modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.Flag, contentDescription = null, tint = colors.accent, modifier = Modifier.size(22.dp))
                                Spacer(Modifier.width(10.dp))
                                Text(
                                    text = "${goal.current} of ${goal.target} books in ${goal.year}",
                                    color = colors.primaryText,
                                    fontSize = DS.FontSize.Body.scaled(metrics),
                                    fontWeight = FontWeight.SemiBold,
                                )
                            }
                            LinearProgressIndicator(
                                progress = { goal.progress.coerceIn(0f, 1f) },
                                modifier = Modifier.fillMaxWidth(),
                                color = colors.accent,
                                trackColor = colors.separator,
                            )
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
                                OutlinedTextField(
                                    value = state.goalInput,
                                    onValueChange = viewModel::updateGoalInput,
                                    label = { Text("Target") },
                                    singleLine = true,
                                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                    modifier = Modifier.weight(1f),
                                )
                                Button(
                                    onClick = viewModel::saveReadingGoal,
                                    enabled = state.goalInput.isNotBlank(),
                                    shape = RoundedCornerShape(999.dp),
                                    colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = Color.White),
                                ) {
                                    Text("Save")
                                }
                            }
                        }
                    }
                } ?: SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    SettingsSectionHeader(title = "Reading Goal")
                    Row(
                        modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        OutlinedTextField(
                            value = state.goalInput,
                            onValueChange = viewModel::updateGoalInput,
                            label = { Text("Books this year") },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            modifier = Modifier.weight(1f),
                        )
                        Button(
                            onClick = viewModel::saveReadingGoal,
                            enabled = state.goalInput.isNotBlank(),
                            shape = RoundedCornerShape(999.dp),
                            colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = Color.White),
                        ) {
                            Text("Set")
                        }
                    }
                }

                SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
                    SettingsSectionHeader(title = "Search")
                    Column(
                        modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        OutlinedTextField(
                            value = state.searchQuery,
                            onValueChange = viewModel::updateSearchQuery,
                            leadingIcon = { Icon(Icons.Default.Search, contentDescription = null) },
                            label = { Text("Find books") },
                            singleLine = true,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        if (state.isSearching) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                                Spacer(Modifier.width(10.dp))
                                Text("Searching Hardcover", color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
                            }
                        }
                        state.searchResults.take(8).forEachIndexed { index, book ->
                            HardcoverSearchRow(book, onAdd = { viewModel.addToLibrary(book) }, onStart = { viewModel.addToLibrary(book, startReading = true) })
                            if (index < state.searchResults.take(8).lastIndex) HorizontalDivider(color = dividerColor)
                        }
                    }
                }

                HardcoverLibrarySection(state.library)
                HardcoverListsSection(state.lists)
                HardcoverActivitySection(state.activity)
            }

            state.error?.let {
                val mono = EnveTheme.eink.monochrome
                HardcoverMessageCard(
                    text = if (mono) "⚠ $it" else it,
                    tint = if (mono) colors.primaryText else HearthRed,
                    onDismiss = viewModel::clearTransientMessage,
                )
            }
            state.message?.let {
                HardcoverMessageCard(text = it, tint = colors.accent, onDismiss = viewModel::clearTransientMessage)
            }

            Spacer(Modifier.height(80.dp.scaled(metrics)))
        }
    }
}

@Composable
private fun HardcoverTokenCard(
    tokenInput: String,
    isSaving: Boolean,
    onTokenChange: (String) -> Unit,
    onSave: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DS.Spacing.XL.scaled(metrics)),
            verticalArrangement = Arrangement.spacedBy(DS.Spacing.MD.scaled(metrics)),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                HardcoverIcon(Icons.Default.VerifiedUser)
                Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
                Column {
                    Text(
                        "Connect Hardcover",
                        color = colors.primaryText,
                        fontSize = DS.FontSize.Headline.scaled(metrics),
                        fontWeight = FontWeight.Bold,
                    )
                    Text(
                        "Paste your Hardcover API token to enable library, lists, goals, and search.",
                        color = colors.secondaryText,
                        fontSize = DS.FontSize.Caption.scaled(metrics),
                    )
                }
            }
            EnveSecureTextField(
                value = tokenInput,
                onValueChange = onTokenChange,
                label = "API Token",
                placeholder = "Bearer token",
                icon = Icons.Default.VerifiedUser,
            )
            Button(
                onClick = onSave,
                enabled = tokenInput.isNotBlank() && !isSaving,
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(999.dp),
                colors = ButtonDefaults.buttonColors(containerColor = colors.accent, contentColor = Color.White),
            ) {
                if (isSaving) {
                    CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp, color = Color.White)
                    Spacer(Modifier.width(8.dp))
                }
                Text("Connect")
            }
        }
    }
}

@Composable
private fun HardcoverAccountCard(
    username: String,
    isLoading: Boolean,
    onDisconnect: () -> Unit,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DS.Spacing.XL.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            HardcoverIcon(Icons.Default.AutoStories)
            Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    if (username.isBlank()) "Hardcover" else "@$username",
                    color = colors.primaryText,
                    fontSize = DS.FontSize.Headline.scaled(metrics),
                    fontWeight = FontWeight.Bold,
                )
                Text(
                    if (isLoading) "Refreshing library data" else "Connected",
                    color = colors.secondaryText,
                    fontSize = DS.FontSize.Caption.scaled(metrics),
                )
            }
            TextButton(onClick = onDisconnect) {
                Text("Disconnect", color = if (EnveTheme.eink.monochrome) colors.primaryText else HearthRed)
            }
        }
    }
}

@Composable
private fun HardcoverLibrarySection(books: List<HardcoverLibraryBook>) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = "My Library")
        if (books.isEmpty()) {
            EmptyHardcoverText("No Hardcover library books returned.")
        } else {
            books.take(8).forEachIndexed { index, book ->
                HardcoverLibraryRow(book)
                if (index < books.take(8).lastIndex) HorizontalDivider(color = colors.separator.copy(alpha = 0.3f))
            }
        }
    }
}

@Composable
private fun HardcoverListsSection(lists: List<HardcoverUserList>) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = "My Lists")
        if (lists.isEmpty()) {
            EmptyHardcoverText("No Hardcover lists found.")
        } else {
            lists.take(8).forEachIndexed { index, list ->
                HardcoverListRow(list)
                if (index < lists.take(8).lastIndex) HorizontalDivider(color = colors.separator.copy(alpha = 0.3f))
            }
        }
    }
}

@Composable
private fun HardcoverActivitySection(activity: List<HardcoverActivity>) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        SettingsSectionHeader(title = "Activity")
        if (activity.isEmpty()) {
            EmptyHardcoverText("No recent Hardcover activity.")
        } else {
            activity.take(8).forEachIndexed { index, item ->
                HardcoverActivityRow(item)
                if (index < activity.take(8).lastIndex) HorizontalDivider(color = colors.separator.copy(alpha = 0.3f))
            }
        }
    }
}

@Composable
private fun HardcoverSearchRow(
    book: HardcoverBookResult,
    onAdd: () -> Unit,
    onStart: () -> Unit,
) {
    HardcoverBookRow(
        coverUrl = book.coverUrl,
        title = book.title,
        subtitle = listOfNotNull(book.author, book.releaseYear?.toString()).joinToString(" • "),
        trailing = {
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Button(
                    onClick = onAdd,
                    contentPadding = ButtonDefaults.ButtonWithIconContentPadding,
                    shape = RoundedCornerShape(999.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = EnveTheme.colors.accent, contentColor = Color.White),
                ) {
                    Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(4.dp))
                    Text("Add")
                }
                TextButton(onClick = onStart) { Text("Start") }
            }
        },
    )
}

@Composable
private fun HardcoverLibraryRow(book: HardcoverLibraryBook) {
    val progressPct = (book.progress * 100f).roundToInt().takeIf { it > 0 }
    HardcoverBookRow(
        coverUrl = book.coverUrl,
        title = book.title,
        subtitle = listOfNotNull(book.author, book.statusLabel, progressPct?.let { "$it%" }).joinToString(" • "),
        trailing = {
            if (book.statusId == 3) {
                Icon(Icons.Default.CheckCircle, contentDescription = null, tint = EnveTheme.colors.accent)
            }
        },
    )
}

@Composable
private fun HardcoverListRow(list: HardcoverUserList) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        HardcoverIcon(Icons.AutoMirrored.Filled.List, size = 44.dp.scaled(metrics))
        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                list.name,
                color = colors.primaryText,
                fontSize = DS.FontSize.Body.scaled(metrics),
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            list.description?.takeIf { it.isNotBlank() }?.let {
                Text(it, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics), maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Text("${list.booksCount} books", color = colors.tertiaryText, fontSize = DS.FontSize.Caption.scaled(metrics))
        }
    }
}

@Composable
private fun HardcoverActivityRow(item: HardcoverActivity) {
    HardcoverBookRow(
        coverUrl = item.coverUrl,
        title = item.bookTitle ?: "Hardcover activity",
        subtitle = listOfNotNull(item.action, item.author).joinToString(" • "),
        leadingIcon = Icons.Default.Sync,
    )
}

@Composable
private fun HardcoverBookRow(
    coverUrl: String?,
    title: String,
    subtitle: String,
    leadingIcon: ImageVector = Icons.Default.Book,
    trailing: @Composable (() -> Unit)? = null,
) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (!coverUrl.isNullOrBlank()) {
            AsyncImage(
                model = coverUrl,
                contentDescription = title,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(width = 42.dp.scaled(metrics), height = 60.dp.scaled(metrics))
                    .clip(RoundedCornerShape(if (EnveTheme.eink.sharpCorners) 2.dp else 6.dp)),
            )
        } else {
            HardcoverIcon(leadingIcon, size = 48.dp.scaled(metrics))
        }
        Spacer(Modifier.width(DS.Spacing.MD.scaled(metrics)))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                color = colors.primaryText,
                fontSize = DS.FontSize.Body.scaled(metrics),
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (subtitle.isNotBlank()) {
                Text(subtitle, color = colors.secondaryText, fontSize = DS.FontSize.Caption.scaled(metrics), maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        if (trailing != null) {
            Spacer(Modifier.width(DS.Spacing.SM.scaled(metrics)))
            trailing()
        }
    }
}

@Composable
private fun HardcoverIcon(icon: ImageVector, size: androidx.compose.ui.unit.Dp = 52.dp) {
    val colors = EnveTheme.colors
    val shape = RoundedCornerShape(if (EnveTheme.eink.sharpCorners) 4.dp else 12.dp)
    Box(
        modifier = Modifier
            .size(size)
            .clip(shape)
            .then(
                if (EnveTheme.eink.suppressGradients) {
                    Modifier.border(1.dp, colors.primaryText, shape)
                } else {
                    Modifier.background(colors.accent.copy(alpha = 0.14f))
                }
            ),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, contentDescription = null, tint = if (EnveTheme.eink.monochrome) colors.primaryText else colors.accent)
    }
}

@Composable
private fun EmptyHardcoverText(text: String) {
    val metrics = rememberAdaptiveMetrics()
    Text(
        text = text,
        color = EnveTheme.colors.secondaryText,
        fontSize = DS.FontSize.Caption.scaled(metrics),
        modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics), vertical = DS.Spacing.MD.scaled(metrics)),
    )
}

@Composable
private fun HardcoverMessageCard(text: String, tint: Color, onDismiss: () -> Unit) {
    val colors = EnveTheme.colors
    val metrics = rememberAdaptiveMetrics()
    SettingsCard(modifier = Modifier.padding(horizontal = DS.Spacing.LG.scaled(metrics))) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(DS.Spacing.LG.scaled(metrics)),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(text, color = tint, fontSize = DS.FontSize.Body.scaled(metrics), modifier = Modifier.weight(1f))
            TextButton(onClick = onDismiss) { Text("Dismiss", color = colors.accent, fontSize = DS.FontSize.Caption.scaled(metrics)) }
        }
    }
}
