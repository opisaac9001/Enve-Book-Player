package com.enve.wear.listening

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.Text
import androidx.work.WorkInfo

@Composable
fun WatchListeningScreen(model: WatchListeningViewModel, phoneContent: @Composable () -> Unit) {
    val state by model.state.collectAsStateWithLifecycle()
    val library by model.store.state.collectAsStateWithLifecycle()
    val player by WatchPlaybackService.state.collectAsStateWithLifecycle()
    var page by rememberSaveable { mutableStateOf("home") }
    var linkAccountCount by rememberSaveable { mutableIntStateOf(0) }
    var selected by remember { mutableStateOf<WatchBook?>(null) }
    val context = LocalContext.current
    val scroll = rememberScrollState()
    LaunchedEffect(page, selected?.key) { scroll.scrollTo(0) }
    BackHandler(page != "home") { page = "home" }
    if (page == "phone") {
        phoneContent()
        return
    }
    Column(Modifier.fillMaxSize().background(Color.Black).verticalScroll(scroll).padding(horizontal = 24.dp, vertical = 36.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        if (page != "link") Text("ENVE", color = Color(0xFFF5921A))
        if (state.loading) Text("Loading…")
        state.error?.let { Text(it, textAlign = TextAlign.Center, color = Color(0xFFFFB4AB)) }
        when (page) {
            "home" -> {
                Text("On your watch")
                if (player.book != null) WatchButton("Now playing") { page = "player" }
                WatchButton("Downloads · ${library.books.count { it.downloaded }}") { page = "downloads" }
                if (state.signedIn) WatchButton(state.activeAccount?.source?.displayName ?: "Library") { model.libraries(); page = "libraries" }
                else WatchButton("Link from phone") { linkAccountCount = state.accounts.size; model.refreshPhoneLink(); page = "link" }
                WatchButton("Control phone") { page = "phone" }
                WatchButton("Settings") { page = "settings" }
            }
            "link" -> {
                LaunchedEffect(state.accounts.size) { if (state.accounts.size > linkAccountCount) page = "libraries" }
                Text("In Enve on your phone", style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center, color = Color(0xFFBDBDBD), modifier = Modifier.padding(top = 8.dp))
                Text("Library Connections", style = MaterialTheme.typography.titleSmall, textAlign = TextAlign.Center, color = Color(0xFFF5921A))
                Text("› Send to watch", style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center, color = Color(0xFFBDBDBD))
                WatchButton("Restart link") { model.refreshPhoneLink() }
            }
            "libraries" -> {
                Text("Libraries")
                state.libraries.forEach { choice -> WatchButton(choice.name) { model.books(choice); page = "books" } }
                if (!state.loading && state.libraries.isEmpty()) Text("No book libraries found.", textAlign = TextAlign.Center)
                WatchButton("Refresh") { model.libraries() }
            }
            "books" -> {
                Text(state.library?.name.orEmpty(), textAlign = TextAlign.Center)
                state.books.forEach { book -> WatchButton(book.title) { selected = book; page = "book" } }
                if (!state.loading && state.books.isEmpty()) Text("No audiobooks on this page.", textAlign = TextAlign.Center)
                if (state.hasMore) WatchButton("More books") { state.library?.let { model.books(it, true) } }
            }
            "downloads" -> {
                Text("Downloads")
                library.books.forEach { book -> WatchButton(book.title + if (book.downloaded) " · Ready" else " · Incomplete") { selected = book; page = "book" } }
                if (library.books.isEmpty()) Text("Download a book from your library to listen without your phone.", textAlign = TextAlign.Center)
            }
            "book" -> selected?.let { original ->
                val book = library.books.firstOrNull { it.key == original.key } ?: original
                val jobs by remember(book.key) { model.work.getWorkInfosForUniqueWorkFlow("watch-download-${book.key}") }.collectAsStateWithLifecycle(emptyList())
                val job = jobs.firstOrNull()
                val downloading = job?.state == WorkInfo.State.RUNNING || job?.state == WorkInfo.State.ENQUEUED || job?.state == WorkInfo.State.BLOCKED
                Text(book.title, textAlign = TextAlign.Center)
                Text(book.author, textAlign = TextAlign.Center)
                Text(watchTime(book.durationMs))
                library.progressConflicts[book.key]?.let { conflict ->
                    Text("Progress differs", color = Color(0xFFF5921A))
                    Text("Watch ${watchTime(conflict.localPositionMs)} · Server ${watchTime(conflict.remotePositionMs)}", textAlign = TextAlign.Center)
                    WatchButton("Keep watch position") { model.useWatchProgress(book) }
                    WatchButton("Use server position") { model.useServerProgress(book) }
                }
                if (book.downloaded) {
                    Text("Ready offline", color = Color(0xFFF5921A))
                    WatchButton("Play on watch") {
                        if (WatchPlaybackService.hasHeadphones(context)) { model.play(book, false); page = "player" }
                        else page = "headphones"
                    }
                    WatchButton("Remove download") { model.remove(book) }
                    WatchButton("Sync progress") { model.sync(book) }
                } else {
                    if (downloading) {
                        Text(if (job.state == WorkInfo.State.ENQUEUED) "Waiting for Wi-Fi or retry" else "Downloading track ${job.progress.getInt("track", 1)} of ${job.progress.getInt("total", 1)}", textAlign = TextAlign.Center)
                        WatchButton("Pause download") { model.pauseDownload(book) }
                    } else {
                        job?.outputData?.getString("error")?.let { Text(it, textAlign = TextAlign.Center) }
                        WatchButton(if (job == null) "Download to watch" else "Resume download", enabled = state.signedIn) { model.download(book) }
                    }
                    Text("Downloads use Wi-Fi. Progress syncs when the service supports it.", textAlign = TextAlign.Center)
                }
            }
            "headphones" -> {
                Text("Connect headphones to your watch", textAlign = TextAlign.Center)
                WatchButton("Open Bluetooth") { context.startActivity(android.content.Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS)) }
                WatchButton("Try headphones again") {
                    if (WatchPlaybackService.hasHeadphones(context)) {
                        selected?.let { model.play(library.books.firstOrNull { saved -> saved.key == it.key } ?: it, false) }
                        page = "player"
                    }
                }
                WatchButton("Use watch speaker") {
                    selected?.let { model.play(library.books.firstOrNull { saved -> saved.key == it.key } ?: it, true) }
                    page = "player"
                }
            }
            "player" -> {
                Text(player.book?.title ?: "Opening book…", textAlign = TextAlign.Center)
                player.error?.let { Text(it, textAlign = TextAlign.Center) }
                Text("${watchTime(player.positionMs)} / ${watchTime(player.book?.durationMs ?: 0)}")
                WatchButton(if (player.playing) "Pause" else "Play") { WatchPlaybackService.active?.toggle() }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Button(onClick = { WatchPlaybackService.active?.seek(player.positionMs - 30_000) }, modifier = Modifier.weight(1f)) { Text("−30") }
                    Button(onClick = { WatchPlaybackService.active?.seek(player.positionMs + 30_000) }, modifier = Modifier.weight(1f)) { Text("+30") }
                }
                WatchButton("Speed · ${player.speed}×") { page = "speed" }
                WatchButton("Chapters") { page = "chapters" }
                WatchButton("Bookmarks") { page = "bookmarks" }
                WatchButton(if (player.sleepAt == null) "Sleep timer" else "Cancel sleep timer") {
                    if (player.sleepAt == null) page = "sleep" else WatchPlaybackService.active?.sleep(0)
                }
                WatchButton("Close book") { context.stopService(android.content.Intent(context, WatchPlaybackService::class.java)); page = "home" }
            }
            "speed" -> listOf(0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f).forEach { speed -> WatchButton("${speed}×") { WatchPlaybackService.active?.speed(speed); page = "player" } }
            "chapters" -> {
                player.book?.chapters.orEmpty().forEach { chapter -> WatchButton(chapter.title) { WatchPlaybackService.active?.seek(chapter.startMs); page = "player" } }
                if (player.book?.chapters.isNullOrEmpty()) Text("No chapter markers.")
            }
            "bookmarks" -> {
                WatchButton("Bookmark this position") { WatchPlaybackService.active?.bookmark() }
                library.positions[player.book?.key]?.bookmarks.orEmpty().forEach { position -> WatchButton(watchTime(position)) { WatchPlaybackService.active?.seek(position); page = "player" } }
            }
            "sleep" -> listOf(15, 30, 45, 60).forEach { minutes -> WatchButton("$minutes minutes") { WatchPlaybackService.active?.sleep(minutes); page = "player" } }
            "settings" -> {
                Text("Progress syncs with supported services. Bookmarks stay on this watch.", textAlign = TextAlign.Center)
                state.accounts.forEach { account ->
                    val active = account.key == state.activeAccount?.key
                    WatchButton((if (active) "✓ " else "") + "${account.source.displayName} · ${account.username}") {
                        model.selectAccount(account.key)
                    }
                }
                WatchButton("Add another service") { linkAccountCount = state.accounts.size; model.refreshPhoneLink(); page = "link" }
                if (state.signedIn) WatchButton("Sign out") { model.signOut(); page = "home" }
            }
        }
        if (page != "home") WatchButton("Home") { page = "home" }
    }
}

@Composable
private fun WatchButton(text: String, enabled: Boolean = true, action: () -> Unit) {
    Button(onClick = action, enabled = enabled, modifier = Modifier.fillMaxWidth()) { Text(text, textAlign = TextAlign.Center) }
}

private fun watchTime(milliseconds: Long): String {
    val seconds = milliseconds.coerceAtLeast(0) / 1000
    return if (seconds >= 3600) "%d:%02d:%02d".format(seconds / 3600, seconds / 60 % 60, seconds % 60) else "%d:%02d".format(seconds / 60, seconds % 60)
}
