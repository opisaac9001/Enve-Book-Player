package com.enve.hearth.listeningposition

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.enve.core.data.model.Book
import com.enve.core.data.model.AppMediaType
import com.enve.core.listeningposition.SharedReadingLocation
import com.enve.core.listeningposition.ListeningPositionPayload
import com.enve.engine.listeningposition.*
import com.enve.hearth.design.*
import com.enve.hearth.shell.profileViewModel
import com.enve.hearth.shell.LocalProfileViewModelFactory
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun ListeningPositionShareSheet(book: Book, onClose: () -> Unit) {
    val vm: ListeningPositionViewModel = viewModel(key = "listening-position-share", factory = LocalProfileViewModelFactory.current)
    val state by vm.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(book.uniqueKey) { vm.captureShare(book) }
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        PositionPage("Share book position", onClose) {
            val payload = state.sharePayload
            if (payload == null) {
                Text(if (book.mediaType == AppMediaType.EBOOK)
                    "This book's location is unavailable or too large for one QR code."
                    else "Enve needs this book's saved position before it can make a code.",
                    style = HearthText.Body, color = Hearth.palette.textSecondary)
            } else {
                SharedSummary(payload)
                val bitmap by produceState<android.graphics.Bitmap?>(null, payload) {
                    value = withContext(Dispatchers.Default) { ListeningPositionQRCode.image(payload.encoded()) }
                }
                bitmap?.let { image ->
                    Image(image.asImageBitmap(), "Book-position code for ${payload.title} at ${positionLabel(payload)}",
                        Modifier.widthIn(max = 320.dp).fillMaxWidth().aspectRatio(1f).background(Color.White).align(Alignment.CenterHorizontally).testTag("listening-position-qr"), filterQuality = FilterQuality.None)
                    Text("They open Enve's Library, choose More, then Scan book position. This code contains only the book's details and position.", style = HearthText.Body, color = Hearth.palette.textSecondary)
                    QuietButton("Share image", {
                        scope.launch {
                            try { ListeningPositionQRCode.share(context, image) }
                            catch (error: CancellationException) { throw error }
                            catch (_: Exception) { error = "Couldn't share the image. Try again." }
                        }
                    })
                } ?: CircularProgressIndicator(color = Hearth.palette.ember)
                QuietButton("Update position", { vm.captureShare(book) })
                error?.let { Text(it, color = Hearth.palette.textSecondary) }
            }
        }
    }
}

@Composable
fun ListeningPositionScanScreen(onClose: () -> Unit) {
    val vm: ListeningPositionViewModel = profileViewModel()
    val state by vm.state.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var readingImage by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf<ListeningPositionCandidate?>(null) }
    LaunchedEffect(Unit) { vm.reset() }
    val choose = rememberLauncherForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) scope.launch {
            readingImage = true
            try {
                val messages = ListeningPositionQRCode.messages(context, uri)
                val valid = messages.firstOrNull { runCatching { ListeningPositionPayload.decode(it) }.isSuccess }
                val message = valid ?: messages.firstOrNull()
                if (message != null) vm.scan(message) else vm.imageError()
            } catch (error: CancellationException) { throw error }
            catch (_: Exception) { vm.imageError() }
            finally { readingImage = false }
        }
    }
    val back: () -> Unit = {
        if (!state.applying) {
            if (selected != null && state.result == null) { selected = null; vm.clearResult() } else onClose()
        }
    }
    PositionPage(if (state.payload == null) "Scan book position" else if (selected == null) "Shared book position" else "Move your copy", back, !state.applying, if (selected == null) "Close" else "Back") {
        val payload = state.payload
        val candidate = selected
        if (payload == null) {
            Text("Scan a code shown in Enve or choose a screenshot. You'll pick which of your books to move before anything changes.", style = HearthText.Body, color = Hearth.palette.textSecondary)
            ListeningPositionCameraScanner(vm::scan)
            if (readingImage) CircularProgressIndicator(color = Hearth.palette.ember)
            else QuietButton("Choose an image", { choose.launch("image/*") }, Modifier.testTag("listening-position-import"))
        } else if (candidate == null) {
            SharedSummary(payload)
            Overline("Matches in your library")
            if (state.loading) CircularProgressIndicator(color = Hearth.palette.ember)
            else if (state.suggestions.isEmpty()) Text("No matching book was found. Search your library below.", color = Hearth.palette.textSecondary, style = HearthText.Body)
            state.suggestions.forEach { item -> CandidateRow(item) { vm.clearResult(); selected = item } }
            Overline("Search your library")
            OutlinedTextField(state.query, vm::search, Modifier.fillMaxWidth().testTag("listening-position-search"),
                label = { Text("Title, author or narrator") }, singleLine = true,
                colors = OutlinedTextFieldDefaults.colors(focusedTextColor = Hearth.palette.text, unfocusedTextColor = Hearth.palette.text,
                    focusedBorderColor = Hearth.palette.ember, unfocusedBorderColor = Hearth.palette.hairline,
                    focusedLabelColor = Hearth.palette.textSecondary, unfocusedLabelColor = Hearth.palette.textSecondary,
                    cursorColor = Hearth.palette.ember, focusedContainerColor = Hearth.palette.bgSunken, unfocusedContainerColor = Hearth.palette.bgSunken))
            if (state.searching) CircularProgressIndicator(color = Hearth.palette.ember)
            else if (state.query.isNotBlank() && state.search.isEmpty()) Text("No books match that search.", color = Hearth.palette.textSecondary)
            state.search.forEach { item -> CandidateRow(item) { vm.clearResult(); selected = item } }
            QuietButton("Scan a different code", { vm.reset() })
        } else {
            Text(candidate.book.title, style = HearthText.BookTitle, color = Hearth.palette.text)
            Text(candidateByline(candidate), style = HearthText.Caption, color = Hearth.palette.textSecondary)
            Text("Now: ${vm.currentLocation(candidate.book)?.let(::positionLabel) ?: "Unknown position"}", color = Hearth.palette.textSecondary, style = HearthText.Body)
            Text("Shared: ${positionLabel(payload)}", color = Hearth.palette.ember, style = HearthText.BookTitle)
            candidate.warnings.forEach { Text(it, style = HearthText.Body, color = Hearth.palette.textSecondary) }
            Text("This changes where your copy resumes. Enve saves it on this device and sends it to your server if server sync is enabled. It won't start playing.", style = HearthText.Body, color = Hearth.palette.textSecondary)
            val result = state.result
            if (result != null) {
                val server = when (result.server) {
                    ListeningPositionServerStatus.SAVED -> "The server has saved it too."
                    ListeningPositionServerStatus.QUEUED -> "The server hasn't confirmed it yet. The update is queued on this device."
                    ListeningPositionServerStatus.NO_SERVER -> "This copy isn't connected to a progress server."
                    ListeningPositionServerStatus.SYNC_DISABLED -> "Server sync is off; only this device changed."
                    ListeningPositionServerStatus.UNKNOWN_LENGTH -> "This copy's length is unknown, so only this device changed. Refresh its details before syncing the shared time."
                }
                Text("Moved to ${if (result.readingLocation != null) readingPositionLabel(SharedReadingLocation.from(result.book)) else positionClock(result.positionMilliseconds)}. $server", style = HearthText.Body, color = Hearth.palette.text)
                EmberButton("Done", onClose, Modifier.testTag("listening-position-done"))
            } else if (state.applying) {
                CircularProgressIndicator(color = Hearth.palette.ember)
                Text("Saving…", color = Hearth.palette.textSecondary)
            } else if (candidate.canApply) {
                EmberButton("Move to ${positionLabel(payload)}", { vm.apply(candidate) }, Modifier.testTag("listening-position-apply"))
            }
        }
        state.error?.let { Text(it, style = HearthText.Body, color = Hearth.palette.textSecondary, modifier = Modifier.testTag("listening-position-error")) }
    }
}

@Composable
private fun PositionPage(title: String, onClose: () -> Unit, canClose: Boolean = true, closeLabel: String = "Close", content: @Composable ColumnScope.() -> Unit) {
    BackHandler { if (canClose) onClose() }
    Column(Modifier.fillMaxSize().background(Hearth.palette.bg).statusBarsPadding().navigationBarsPadding().imePadding()
        .verticalScroll(rememberScrollState()).padding(24.dp).testTag("listening-position-screen"), verticalArrangement = Arrangement.spacedBy(20.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
            Overline("Book position", Modifier.weight(1f))
            TextButton(onClose, enabled = canClose) { Text(closeLabel, color = Hearth.palette.textSecondary) }
        }
        Text(title, style = HearthText.ScreenTitle, color = Hearth.palette.text)
        content()
        Spacer(Modifier.height(LocalMantelInset.current))
    }
}

@Composable
private fun SharedSummary(payload: ListeningPositionPayload) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(payload.title, style = HearthText.BookTitle, color = Hearth.palette.text)
        if (payload.authors.isNotEmpty()) Text(payload.authors.joinToString(", "), style = HearthText.Body, color = Hearth.palette.textSecondary)
        if (payload.narrators.isNotEmpty()) Text("Narrated by ${payload.narrators.joinToString(", ")}", style = HearthText.Caption, color = Hearth.palette.textSecondary)
        payload.series?.let { Text(listOfNotNull(it, payload.seriesSequence?.let { number -> "Book $number" }).joinToString(" · "), color = Hearth.palette.textSecondary, style = HearthText.Caption) }
        Text(payload.readingLocation?.let(::readingPositionLabel) ?: "${positionClock(payload.positionMilliseconds)} of ${positionClock(payload.durationMilliseconds)}", color = Hearth.palette.ember, style = HearthText.Label)
    }
}

@Composable
private fun CandidateRow(candidate: ListeningPositionCandidate, onClick: () -> Unit) {
    val shape = RoundedCornerShape(if (Hearth.eink.sharpCorners) 0.dp else Hearth.Radius.Inner)
    Column(Modifier.fillMaxWidth().background(Hearth.palette.bgElevated, shape).border(1.dp, Hearth.palette.hairline, shape)
        .clickable(onClick = onClick).padding(16.dp).testTag("listening-position-candidate-${candidate.book.uniqueKey}"), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(candidate.book.title, style = HearthText.Label, color = Hearth.palette.text)
        Text(candidateByline(candidate), style = HearthText.Caption, color = Hearth.palette.textSecondary)
        Text(candidate.warnings.firstOrNull() ?: "Possible match. Review this copy.", style = HearthText.Caption, color = Hearth.palette.textSecondary)
    }
}

private fun candidateByline(candidate: ListeningPositionCandidate): String = listOfNotNull(candidate.book.author,
    candidate.book.narrator?.takeIf { it.isNotBlank() }?.let { "Narrated by $it" },
    candidate.sourceLabel ?: candidate.book.source.displayName, candidate.book.libraryName,
    candidate.book.duration.takeIf { it > 0 && candidate.book.mediaType != AppMediaType.EBOOK }?.let { positionClock(it * 1000) }).filter { it.isNotBlank() }.joinToString(" · ")

internal fun positionClock(milliseconds: Long): String {
    val seconds = milliseconds.coerceAtLeast(0) / 1000
    return if (seconds >= 3600) "%d:%02d:%02d".format(java.util.Locale.ROOT, seconds / 3600, seconds / 60 % 60, seconds % 60)
        else "%d:%02d".format(java.util.Locale.ROOT, seconds / 60, seconds % 60)
}

internal fun positionLabel(payload: ListeningPositionPayload): String =
    payload.readingLocation?.let(::readingPositionLabel) ?: positionClock(payload.positionMilliseconds)

internal fun readingPositionLabel(location: SharedReadingLocation): String = when {
    location.page != null && location.pageCount != null -> "Page ${location.page} of ${location.pageCount}"
    location.page != null -> "Page ${location.page}"
    else -> String.format(java.util.Locale.ROOT, "%.1f%%", location.progression * 100)
}
