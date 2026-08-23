package com.enve.hearth.settings

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.LibraryBooks
import androidx.compose.material.icons.automirrored.outlined.ManageSearch
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Accessibility
import androidx.compose.material.icons.outlined.AudioFile
import androidx.compose.material.icons.outlined.BarChart
import androidx.compose.material.icons.outlined.Book
import androidx.compose.material.icons.outlined.BugReport
import androidx.compose.material.icons.outlined.CloudSync
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.EmojiEvents
import androidx.compose.material.icons.outlined.FolderOff
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.KeyboardArrowUp
import androidx.compose.material.icons.outlined.Palette
import androidx.compose.material.icons.outlined.PhonelinkSetup
import androidx.compose.material.icons.outlined.Storage
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.Translate
import androidx.compose.material.icons.outlined.ViewModule
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.model.ComicPageLoadingMode
import com.enve.engine.eink.EinkMode
import com.enve.engine.prefs.HearthHomeSection
import com.enve.engine.prefs.HearthStartTab
import com.enve.engine.theme.HearthThemeMode
import com.enve.hearth.design.EmberButton
import com.enve.hearth.design.Hearth
import com.enve.hearth.design.HearthChip
import com.enve.hearth.design.HearthText
import com.enve.hearth.design.LocalMantelInset
import com.enve.hearth.design.Overline

private val ACCENTS = listOf(
    "Orange" to "#F5921A",
    "Red" to "#E0533A",
    "Gold" to "#E6A800",
    "Blue" to "#3D91E6",
    "Cyan" to "#3EC2D9",
    "Green" to "#4DD861",
    "Purple" to "#B347E6",
    "Pink" to "#F24693",
)

enum class HearthSettingsDestination {
    Sources,
    ServerManagement,
    LibraryHub,
    Hardcover,
    Metadata,
    StoryAlign,
    Downloads,
    Storage,
    SyncCloud,
    KOReader,
    Obsidian,
    Vocabulary,
    Dictionaries,
    LibraryDisplay,
    HiddenBooks,
    Annotations,
    Stats,
    Achievements,
    Appearance,
    Accessibility,
    Playback,
    About,
    CrashLogs,
    AudioEffects,
}

private enum class SettingsCategory(val label: String, val pageTitle: String, val blurb: String, val icon: ImageVector) {
    Sources("Sources", "Sources", "", Icons.Outlined.Dns),
    Appearance("Home & appearance", "Home & appearance", "Startup, shelves, theme, text size, and e-ink", Icons.Outlined.Palette),
    Library("Library & reading", "Library & reading", "Shelves, annotations, vocabulary, stats", Icons.AutoMirrored.Outlined.LibraryBooks),
    Playback("Playback & audio", "Playback & audio", "Player defaults and audio effects", Icons.Outlined.GraphicEq),
    Downloads("Downloads & sync", "Downloads & sync", "Offline files, storage, sync services", Icons.Outlined.Download),
    Services("Services & tools", "Services & tools", "Server, metadata, StoryAlign, Hardcover", Icons.Outlined.PhonelinkSetup),
    About("About & support", "About & support", "App info and crash logs", Icons.Outlined.Info),
}

@Composable
fun HearthSettingsScreen(
    onBack: () -> Unit,
    onManageSources: () -> Unit,
    onOpenDestination: (HearthSettingsDestination) -> Unit = {},
) {
    val vm: HearthSettingsViewModel = hiltViewModel()
    val connections by vm.connections.collectAsStateWithLifecycle()
    var category by rememberSaveable { mutableStateOf<SettingsCategory?>(null) }
    var selectedConnectionId by rememberSaveable { mutableStateOf<String?>(null) }
    BackHandler(enabled = category != null || selectedConnectionId != null) {
        if (selectedConnectionId != null) selectedConnectionId = null else category = null
    }

    selectedConnectionId?.let { id ->
        val connection = connections.firstOrNull { it.id == id }
        if (connection != null) {
            SourceDetailPage(
                connection = connection,
                onBack = { selectedConnectionId = null },
                onSave = vm::updateConnection,
                onEnabled = { vm.setConnectionEnabled(connection, it) },
                onReauthenticate = onManageSources,
                onDelete = {
                    vm.removeConnection(connection)
                    selectedConnectionId = null
                },
            )
            return
        }
        selectedConnectionId = null
    }

    when (category) {
        null -> SettingsOverview(connections, onBack = onBack, onSelect = { category = it })
        SettingsCategory.Sources -> SourcesPage(
            connections,
            onBack = { category = null },
            onManageSources = onManageSources,
            onSelectConnection = { selectedConnectionId = it },
        )
        SettingsCategory.Appearance -> AppearancePage(vm, onBack = { category = null }, onOpenDestination)
        SettingsCategory.Library -> LibraryPage(vm, onBack = { category = null }, onOpenDestination)
        SettingsCategory.Playback -> PlaybackPage(onBack = { category = null }, onOpenDestination)
        SettingsCategory.Downloads -> DownloadsPage(vm, onBack = { category = null }, onOpenDestination)
        SettingsCategory.Services -> ServicesPage(onBack = { category = null }, onOpenDestination)
        SettingsCategory.About -> AboutPage(onBack = { category = null }, onOpenDestination)
    }
}

@Composable
private fun SettingsOverview(
    connections: List<ProviderConnection>,
    onBack: () -> Unit,
    onSelect: (SettingsCategory) -> Unit,
) {
    val palette = Hearth.palette
    val enabled = connections.count { it.enabled }
    val needsAuth = connections.count { it.needsReauth }
    val sourcesSummary = when {
        connections.isEmpty() -> "No libraries connected"
        needsAuth > 0 -> "${connections.size} source${if (connections.size == 1) "" else "s"} · $needsAuth need${if (needsAuth == 1) "s" else ""} sign-in"
        enabled < connections.size -> "$enabled of ${connections.size} enabled"
        else -> "$enabled connected"
    }
    SettingsPage("Sources & Settings", "Settings", onBack) {
        item {
            QuietCard {
                CategoryRow(
                    SettingsCategory.Sources,
                    subtitle = sourcesSummary,
                    subtitleColor = if (needsAuth > 0) palette.statusWarn else null,
                ) { onSelect(SettingsCategory.Sources) }
            }
        }
        item {
            QuietCard {
                CategoryRow(SettingsCategory.Appearance) { onSelect(SettingsCategory.Appearance) }
                CategoryRow(SettingsCategory.Library) { onSelect(SettingsCategory.Library) }
                CategoryRow(SettingsCategory.Playback) { onSelect(SettingsCategory.Playback) }
                CategoryRow(SettingsCategory.Downloads) { onSelect(SettingsCategory.Downloads) }
            }
        }
        item {
            QuietCard {
                CategoryRow(SettingsCategory.Services) { onSelect(SettingsCategory.Services) }
                CategoryRow(SettingsCategory.About) { onSelect(SettingsCategory.About) }
            }
        }
    }
}

@Composable
private fun SourcesPage(
    connections: List<ProviderConnection>,
    onBack: () -> Unit,
    onManageSources: () -> Unit,
    onSelectConnection: (String) -> Unit,
) {
    SettingsPage("Settings", SettingsCategory.Sources.pageTitle, onBack) {
        item {
            Group("Connected libraries") {
                if (connections.isEmpty()) {
                    Text("No libraries connected.", style = HearthText.Body, color = Hearth.palette.textSecondary)
                } else {
                    connections.forEach { c -> ConnectionRow(c) { onSelectConnection(c.id) } }
                }
                Spacer(Modifier.size(Hearth.Spacing.M))
                EmberButton("Add a source", onClick = onManageSources, leadingIcon = Icons.Outlined.Add)
            }
        }
    }
}

@Composable
private fun AppearancePage(
    vm: HearthSettingsViewModel,
    onBack: () -> Unit,
    onOpenDestination: (HearthSettingsDestination) -> Unit,
) {
    val palette = Hearth.palette
    val themeMode by vm.themeMode.collectAsStateWithLifecycle()
    val oled by vm.oled.collectAsStateWithLifecycle()
    val uiTextScale by vm.uiTextScale.collectAsStateWithLifecycle()
    val accent by vm.accent.collectAsStateWithLifecycle()
    val eink by vm.einkState.collectAsStateWithLifecycle()
    val preferredStartTab by vm.preferredStartTab.collectAsStateWithLifecycle()
    val homeSectionOrder by vm.homeSectionOrder.collectAsStateWithLifecycle()

    SettingsPage("Settings", SettingsCategory.Appearance.pageTitle, onBack) {
        item {
            Group("Home & startup") {
                Overline("Start tab")
                ChipRow(
                    HearthStartTab.entries.map { tab ->
                        tab.label to (tab == preferredStartTab)
                    },
                ) { index -> vm.setPreferredStartTab(HearthStartTab.entries[index]) }
                Text(
                    "Used the next time Enve launches.",
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                )
                Spacer(Modifier.size(Hearth.Spacing.XS))
                Row(
                    Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Overline("Hearth shelf order")
                    HearthChip("Reset", selected = false, onClick = vm::resetHomeSectionOrder)
                }
                homeSectionOrder.forEachIndexed { index, section ->
                    HomeSectionOrderRow(
                        section = section,
                        canMoveUp = index > 0,
                        canMoveDown = index < homeSectionOrder.lastIndex,
                        onMoveUp = { vm.moveHomeSection(section, -1) },
                        onMoveDown = { vm.moveHomeSection(section, 1) },
                    )
                }
                Text(
                    "Only shelves with books appear. The hero and reading pulse stay at the top.",
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                )
            }
        }
        item {
            Group("Theme & accent") {
                ChipRow(HearthThemeMode.entries.map { it.name.lowercase().replaceFirstChar(Char::uppercase) to (it == themeMode) }) { i -> vm.setThemeMode(HearthThemeMode.entries[i]) }
                ToggleRow("OLED black", oled, vm::setOled)
                Overline("Accent")
                Row(
                    Modifier.horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.XS),
                ) {
                    ACCENTS.forEach { (name, hex) ->
                        val c = parse(hex)
                        val selected = accentMatches(accent, hex)
                        Box(
                            Modifier
                                .size(48.dp)
                                .clip(CircleShape)
                                .semantics {
                                    contentDescription = "$name accent"
                                    this.selected = selected
                                }
                                .clickable { vm.setAccent(hex) },
                            contentAlignment = Alignment.Center,
                        ) {
                            Box(
                                Modifier.size(30.dp).clip(CircleShape).background(c)
                                    .border(
                                        if (selected) 2.dp else 1.dp,
                                        if (selected) palette.text else palette.hairline,
                                        CircleShape,
                                    ),
                            )
                        }
                    }
                }
            }
        }
        item {
            Group("Text size") {
                ChipRow(
                    listOf(
                        "Default" to 1f,
                        "Large" to 1.15f,
                        "Extra large" to 1.3f,
                    ).map { (label, scale) ->
                        label to (kotlin.math.abs(uiTextScale - scale) < 0.01f)
                    },
                ) { index -> vm.setUiTextScale(listOf(1f, 1.15f, 1.3f)[index]) }
                Text(
                    "Applies to Enve's menus and reader controls, and combines with your device's font-size setting.",
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                )
            }
        }
        item {
            Group("E-Ink") {
                ChipRow(EinkMode.entries.map { einkModeLabel(it) to (it == eink.mode) }) { i -> vm.setEinkMode(EinkMode.entries[i]) }
                ToggleRow("Bold text", eink.boldText, vm::setEinkBold)
                Spacer(Modifier.size(Hearth.Spacing.S))
                Overline("Refresh strength")
                ChipRow((0..3).map { it.toString() to (it == eink.refreshStrength) }) { i -> vm.setEinkStrength(i) }
            }
        }
        item {
            Group("Reading & access") {
                ToolRow(Icons.Outlined.Palette, "Reader & custom fonts", "Reader display and custom typefaces") {
                    onOpenDestination(HearthSettingsDestination.Appearance)
                }
                ToolRow(Icons.Outlined.Accessibility, "Accessibility", "Motion, contrast, and e-ink controls") {
                    onOpenDestination(HearthSettingsDestination.Accessibility)
                }
            }
        }
    }
}

@Composable
private fun HomeSectionOrderRow(
    section: HearthHomeSection,
    canMoveUp: Boolean,
    canMoveDown: Boolean,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().heightIn(min = 44.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        Icon(Icons.Outlined.Home, contentDescription = null, tint = palette.ember, modifier = Modifier.size(19.dp))
        Text(section.label, style = HearthText.Body, color = palette.text, modifier = Modifier.weight(1f))
        Icon(
            Icons.Outlined.KeyboardArrowUp,
            contentDescription = "Move ${section.label} up",
            tint = if (canMoveUp) palette.textSecondary else palette.textTertiary,
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .clickable(enabled = canMoveUp, onClick = onMoveUp)
                .padding(7.dp),
        )
        Icon(
            Icons.Outlined.KeyboardArrowDown,
            contentDescription = "Move ${section.label} down",
            tint = if (canMoveDown) palette.textSecondary else palette.textTertiary,
            modifier = Modifier
                .size(36.dp)
                .clip(CircleShape)
                .clickable(enabled = canMoveDown, onClick = onMoveDown)
                .padding(7.dp),
        )
    }
}

@Composable
private fun LibraryPage(
    vm: HearthSettingsViewModel,
    onBack: () -> Unit,
    onOpenDestination: (HearthSettingsDestination) -> Unit,
) {
    val palette = Hearth.palette
    val comicPageLoadingMode by vm.comicPageLoadingMode.collectAsStateWithLifecycle()
    SettingsPage("Settings", SettingsCategory.Library.pageTitle, onBack) {
        item {
            Group("Library") {
                ToolRow(Icons.AutoMirrored.Outlined.LibraryBooks, "Library management", "Connections, scans, and bulk actions") {
                    onOpenDestination(HearthSettingsDestination.LibraryHub)
                }
                ToolRow(Icons.Outlined.ViewModule, "Library display", "Grid density, sort defaults, and shelves") {
                    onOpenDestination(HearthSettingsDestination.LibraryDisplay)
                }
                ToolRow(Icons.Outlined.FolderOff, "Hidden books", "Restore or permanently hide items") {
                    onOpenDestination(HearthSettingsDestination.HiddenBooks)
                }
            }
        }
        item {
            Group("Reading") {
                ToolRow(Icons.AutoMirrored.Outlined.ManageSearch, "Annotations", "Bookmarks, highlights, and notes") {
                    onOpenDestination(HearthSettingsDestination.Annotations)
                }
                ToolRow(Icons.Outlined.Translate, "Vocabulary", "Saved words, study mode, and dictionaries") {
                    onOpenDestination(HearthSettingsDestination.Vocabulary)
                }
                ToolRow(Icons.Outlined.Book, "Dictionaries", "Dictionary sources and lookup behavior") {
                    onOpenDestination(HearthSettingsDestination.Dictionaries)
                }
            }
        }
        item {
            Group("Progress") {
                ToolRow(Icons.Outlined.BarChart, "Stats", "Reading totals, streaks, and goals") {
                    onOpenDestination(HearthSettingsDestination.Stats)
                }
                ToolRow(Icons.Outlined.EmojiEvents, "Achievements", "Goals and listening milestones") {
                    onOpenDestination(HearthSettingsDestination.Achievements)
                }
            }
        }
        item {
            Group("Comics") {
                Text("Comic page loading", style = HearthText.Body, color = palette.text)
                Text(
                    if (comicPageLoadingMode == ComicPageLoadingMode.STREAM) {
                        "Loads only nearby pages and keeps storage use bounded."
                    } else {
                        "Caches every page while you read, then removes them when the reader closes."
                    },
                    style = HearthText.Caption,
                    color = palette.textSecondary,
                )
                ChipRow(
                    ComicPageLoadingMode.entries.map { mode ->
                        (if (mode == ComicPageLoadingMode.STREAM) "Stream" else "Preload") to
                            (mode == comicPageLoadingMode)
                    },
                ) { index -> vm.setComicPageLoadingMode(ComicPageLoadingMode.entries[index]) }
            }
        }
    }
}

@Composable
private fun PlaybackPage(
    onBack: () -> Unit,
    onOpenDestination: (HearthSettingsDestination) -> Unit,
) {
    SettingsPage("Settings", SettingsCategory.Playback.pageTitle, onBack) {
        item {
            Group("Playback") {
                ToolRow(Icons.Outlined.Book, "Playback settings", "Skip intervals, sleep timer, and playback defaults") {
                    onOpenDestination(HearthSettingsDestination.Playback)
                }
                ToolRow(Icons.Outlined.GraphicEq, "Audio effects", "Equalizer, boost, and effects controls") {
                    onOpenDestination(HearthSettingsDestination.AudioEffects)
                }
            }
        }
    }
}

@Composable
private fun DownloadsPage(
    vm: HearthSettingsViewModel,
    onBack: () -> Unit,
    onOpenDestination: (HearthSettingsDestination) -> Unit,
) {
    val palette = Hearth.palette
    val refreshing by vm.isRefreshing.collectAsStateWithLifecycle()
    SettingsPage("Settings", SettingsCategory.Downloads.pageTitle, onBack) {
        item {
            Group("Library data") {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                    Text(if (refreshing) "Syncing…" else "Refresh your library", style = HearthText.Body, color = palette.text)
                    HearthChip("Sync now", selected = false, onClick = vm::syncNow)
                }
                ToolRow(Icons.Outlined.Download, "Downloads", "Queue, finished files, and download rules") {
                    onOpenDestination(HearthSettingsDestination.Downloads)
                }
                ToolRow(Icons.Outlined.Storage, "Storage", "Cache, downloaded media, and local cleanup") {
                    onOpenDestination(HearthSettingsDestination.Storage)
                }
            }
        }
        item {
            Group("Sync services") {
                ToolRow(Icons.Outlined.CloudSync, "Sync cloud", "Auto-sync, KOReader credentials, and manual sync") {
                    onOpenDestination(HearthSettingsDestination.SyncCloud)
                }
                ToolRow(Icons.Outlined.Sync, "KOReader", "Progress bridge and sync diagnostics") {
                    onOpenDestination(HearthSettingsDestination.KOReader)
                }
                ToolRow(Icons.Outlined.Book, "Obsidian", "Reading notes and vault export") {
                    onOpenDestination(HearthSettingsDestination.Obsidian)
                }
            }
        }
    }
}

@Composable
private fun ServicesPage(
    onBack: () -> Unit,
    onOpenDestination: (HearthSettingsDestination) -> Unit,
) {
    SettingsPage("Settings", SettingsCategory.Services.pageTitle, onBack) {
        item {
            Group("Services") {
                ToolRow(Icons.Outlined.PhonelinkSetup, "Server Hub", "Personal insights, health, and admin tools") {
                    onOpenDestination(HearthSettingsDestination.ServerManagement)
                }
                ToolRow(Icons.AutoMirrored.Outlined.ManageSearch, "Metadata", "Matches, duplicates, and enrichment tools") {
                    onOpenDestination(HearthSettingsDestination.Metadata)
                }
                ToolRow(Icons.Outlined.AudioFile, "StoryAlign", "Create read-aloud books from an ebook + audiobook") {
                    onOpenDestination(HearthSettingsDestination.StoryAlign)
                }
                ToolRow(Icons.AutoMirrored.Outlined.LibraryBooks, "Hardcover", "Reading sync and book profile integration") {
                    onOpenDestination(HearthSettingsDestination.Hardcover)
                }
            }
        }
    }
}

@Composable
private fun AboutPage(
    onBack: () -> Unit,
    onOpenDestination: (HearthSettingsDestination) -> Unit,
) {
    val palette = Hearth.palette
    val ctx = LocalContext.current
    val version = remember(ctx) {
        runCatching { ctx.packageManager.getPackageInfo(ctx.packageName, 0).versionName }.getOrNull() ?: ""
    }
    SettingsPage("Settings", SettingsCategory.About.pageTitle, onBack) {
        item {
            Group("App & support") {
                ToolRow(Icons.Outlined.Info, "About Enve", "Website, privacy, and support") {
                    onOpenDestination(HearthSettingsDestination.About)
                }
                ToolRow(Icons.Outlined.BugReport, "Crash logs", "Recent startup and runtime diagnostics") {
                    onOpenDestination(HearthSettingsDestination.CrashLogs)
                }
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Version", style = HearthText.Body, color = palette.text)
                    Text(version, style = HearthText.Caption, color = palette.textTertiary)
                }
            }
        }
    }
}

@Composable
private fun SettingsPage(
    overline: String,
    title: String,
    onBack: () -> Unit,
    content: LazyListScope.() -> Unit,
) {
    val palette = Hearth.palette
    Column(Modifier.fillMaxSize().background(palette.bg)) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(Hearth.Spacing.S), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(48.dp).clip(CircleShape).clickable(onClick = onBack),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back", tint = palette.text, modifier = Modifier.size(26.dp))
            }
            Spacer(Modifier.size(Hearth.Spacing.S))
            Column(Modifier.weight(1f)) {
                Overline(overline)
                Text(title, style = HearthText.ScreenTitle, color = palette.text, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
        }
        LazyColumn(
            contentPadding = PaddingValues(
                start = Hearth.Spacing.L, end = Hearth.Spacing.L,
                top = Hearth.Spacing.M, bottom = LocalMantelInset.current + Hearth.Spacing.XL,
            ),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.L),
            content = content,
        )
    }
}

@Composable
private fun QuietCard(content: @Composable ColumnScope.() -> Unit) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Card)
    Column(
        Modifier.fillMaxWidth().clip(shape).background(palette.bgElevated)
            .border(1.dp, palette.hairline, shape).padding(Hearth.Spacing.XS),
        content = content,
    )
}

@Composable
private fun CategoryRow(
    category: SettingsCategory,
    subtitle: String = category.blurb,
    subtitleColor: Color? = null,
    onClick: () -> Unit,
) {
    val palette = Hearth.palette
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Inner)).clickable(onClick = onClick)
            .heightIn(min = 48.dp).padding(horizontal = Hearth.Spacing.S, vertical = Hearth.Spacing.S),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Icon(category.icon, contentDescription = null, tint = palette.ember, modifier = Modifier.size(22.dp))
        Column(Modifier.weight(1f)) {
            Text(category.label, style = HearthText.Label, color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, style = HearthText.Caption, color = subtitleColor ?: palette.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        Icon(Icons.Outlined.ChevronRight, contentDescription = null, tint = palette.textTertiary, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun ToolRow(icon: ImageVector, title: String, subtitle: String, onClick: () -> Unit) {
    val palette = Hearth.palette
    val shape = RoundedCornerShape(Hearth.Radius.Inner)
    Row(
        Modifier.fillMaxWidth().clip(shape).clickable(onClick = onClick)
            .heightIn(min = 48.dp).padding(vertical = Hearth.Spacing.XS),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.M),
    ) {
        Box(
            Modifier.size(38.dp).clip(RoundedCornerShape(12.dp)).background(palette.bgSunken)
                .border(1.dp, palette.hairline, RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = palette.ember, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = HearthText.Label, color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(subtitle, style = HearthText.Caption, color = palette.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

@Composable
private fun Group(title: String, content: @Composable ColumnScope.() -> Unit) {
    val palette = Hearth.palette
    Column(verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S)) {
        Overline(title)
        Column(
            Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Card)).background(palette.bgElevated)
                .border(1.dp, palette.hairline, RoundedCornerShape(Hearth.Radius.Card)).padding(Hearth.Spacing.M),
            verticalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
            content = content,
        )
    }
}

private typealias ColumnScope = androidx.compose.foundation.layout.ColumnScope

@Composable
private fun ChipRow(options: List<Pair<String, Boolean>>, onSelect: (Int) -> Unit) {
    Row(
        Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(Hearth.Spacing.S),
    ) {
        options.forEachIndexed { i, (label, selected) ->
            HearthChip(label, selected = selected, onClick = { onSelect(i) })
        }
    }
}

@Composable
private fun ToggleRow(label: String, checked: Boolean, onCheck: (Boolean) -> Unit) {
    val palette = Hearth.palette
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = HearthText.Body, color = palette.text)
        Switch(
            checked = checked, onCheckedChange = onCheck,
            colors = SwitchDefaults.colors(checkedTrackColor = palette.ember, checkedThumbColor = palette.readableOnEmber),
        )
    }
}

@Composable
private fun ConnectionRow(c: ProviderConnection, onClick: () -> Unit) {
    val palette = Hearth.palette
    val statusColor = when {
        c.needsReauth -> palette.statusWarn
        c.enabled -> palette.statusOK
        else -> palette.textTertiary
    }
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Hearth.Radius.Inner)).clickable(onClick = onClick)
            .heightIn(min = 48.dp).padding(vertical = Hearth.Spacing.XS),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(statusColor))
        Spacer(Modifier.size(Hearth.Spacing.M))
        Column(Modifier.weight(1f)) {
            Text(c.name.ifBlank { c.source.name }, style = HearthText.Label, color = palette.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(c.serverUrl, style = HearthText.Caption, color = palette.textTertiary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (c.needsReauth) Text("Needs sign-in", style = HearthText.Caption, color = palette.statusWarn)
        }
        Icon(
            Icons.Outlined.ChevronRight, "Edit", tint = palette.textTertiary,
            modifier = Modifier.padding(Hearth.Spacing.XS).size(20.dp),
        )
    }
}

private fun parse(hex: String): Color {
    val v = hex.removePrefix("#").toLongOrNull(16) ?: return Hearth_ember
    return Color(0xFF000000 or v)
}
private val Hearth_ember = Color(0xFFF5921A)
private fun accentMatches(current: String, hex: String) = current.removePrefix("#").equals(hex.removePrefix("#"), ignoreCase = true)
private fun einkModeLabel(m: EinkMode) = when (m) {
    EinkMode.OFF -> "Off"; EinkMode.AUTO -> "Auto"; EinkMode.ON -> "On"; EinkMode.ON_COLOR -> "On (color)"
}
