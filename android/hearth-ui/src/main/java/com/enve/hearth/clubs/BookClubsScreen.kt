package com.enve.hearth.clubs

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.engine.clubs.*
import com.enve.hearth.design.Hearth
import java.text.DateFormat
import java.text.Normalizer
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch

@Composable
fun BookClubsScreen(
    clubs: ClubsFacade,
    inventory: Flow<List<Book>>,
    invitation: String?,
    firstBook: Book?,
    onClose: () -> Unit,
    onOpenBook: (Book, Long?) -> Unit,
    onFindPassage: (Book, String) -> Unit,
) {
    val palette = Hearth.palette
    val scope = rememberCoroutineScope()
    val account by clubs.account.collectAsState()
    val books by inventory.collectAsState(initial = emptyList())
    val supported = remember(books) { books.filter { it.mediaType in setOf(AppMediaType.AUDIOBOOK, AppMediaType.EBOOK) } }
    var selected by remember { mutableStateOf<String?>(null) }
    var form by remember { mutableStateOf<Form?>(null) }
    var listing by remember { mutableStateOf<List<ClubSummary>>(emptyList()) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var handledInvite by remember(invitation, firstBook) { mutableStateOf(false) }
    var restoring by remember { mutableStateOf(false) }
    var name by remember { mutableStateOf("") }
    var recovery by remember { mutableStateOf("") }

    fun perform(action: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            try { action() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { error = failure.message ?: "Book Clubs is temporarily unavailable." }
            finally { busy = false }
        }
    }

    LaunchedEffect(account?.id, selected, invitation, firstBook) {
        val user = account ?: return@LaunchedEffect
        if (!handledInvite) {
            handledInvite = true
            form = when {
                invitation != null -> Form.Join(invitation)
                firstBook != null -> Form.Create(firstBook)
                else -> form
            }
        }
        if (selected == null && user.id == account?.id) {
            try { listing = clubs.clubs(); error = null }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { error = failure.message }
        }
    }

    BackHandler { if (selected != null) selected = null else onClose() }
    val clubID = selected
    if (clubID != null && account != null) {
        key(clubID) {
            ClubRoom(clubs, clubID, checkNotNull(account), supported, onBack = { selected = null }, onOpenBook = onOpenBook, onFindPassage = onFindPassage)
        }
        return
    }
    ClubPage("Book Clubs", onClose) {
        if (account == null) {
            Text("Read the same book with friends", color = palette.text, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
            Text("Members see your display name and what you choose to share in the club.", color = palette.textSecondary)
            if (restoring) OutlinedTextField(recovery, { recovery = it }, label = { Text("Recovery key") },
                visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
            else OutlinedTextField(name, { name = it }, label = { Text("Display name") }, modifier = Modifier.fillMaxWidth())
            Button(onClick = { perform {
                if (restoring) clubs.restoreProfile(recovery) else clubs.createProfile(name)
                recovery = ""
            } }, enabled = !busy && (if (restoring) recovery else name).isNotBlank()) {
                Text(if (restoring) "Restore Clubs Profile" else "Create Clubs Profile")
            }
            TextButton({ restoring = !restoring }) { Text(if (restoring) "Create a profile" else "I already have a profile") }
        } else {
            Row(Modifier.horizontalScroll(rememberScrollState())) {
                Button({ form = Form.Create(null) }) { Text("Start a Club") }
                TextButton({ form = Form.Join("") }) { Text("Join a Club") }
                TextButton({ form = Form.Account }) { Text("Account") }
            }
            if (listing.isEmpty()) Text("Your private reading groups will appear here.", color = palette.textSecondary)
            listing.forEach { club ->
                HorizontalDivider()
                TextButton({ selected = club.id }, modifier = Modifier.fillMaxWidth()) {
                    Column(Modifier.fillMaxWidth()) {
                        Text(club.name, fontWeight = FontWeight.SemiBold)
                        club.currentTitle?.let { Text(it, color = palette.textSecondary) }
                    }
                }
            }
        }
        error?.let { Text(it, color = palette.textSecondary) }
    }
    when (val current = form) {
        is Form.Create -> ClubPlanForm("Start a Club", current.book, clubNameRequired = true, onCancel = { form = null }) { clubName, draft ->
            perform {
                val id = clubs.createClub(clubName, draft)
                if (current.book != null) {
                    clubs.club(id).current?.let { read -> clubs.linkCopy(id, clubs.read(id, read.id), current.book) }
                }
                form = null
                selected = id
            }
        }
        is Form.Join -> ClubInput("Join a Club", "Invite code", current.code, { form = null }, button = "Join") { code ->
            perform { selected = clubs.join(code); form = null }
        }
        Form.Account -> ClubAccountDialog(clubs, busy, { form = null }, perform = { action -> perform(action) })
        else -> Unit
    }
}

private sealed interface Form {
    data class Create(val book: Book?) : Form
    data class Join(val code: String) : Form
    data object Account : Form
}

@Composable
private fun ClubAccountDialog(clubs: ClubsFacade, busy: Boolean, close: () -> Unit, perform: (suspend () -> Unit) -> Unit) {
    var showKey by remember { mutableStateOf(false) }
    var destructive by remember { mutableStateOf<String?>(null) }
    val context = LocalContext.current
    AlertDialog(onDismissRequest = close, title = { Text("Clubs account") }, text = {
        Column {
            Text(clubs.account.value?.name.orEmpty())
            TextButton({ showKey = !showKey }) { Text(if (showKey) "Hide recovery key" else "Show recovery key") }
            if (showKey) {
                androidx.compose.foundation.text.selection.SelectionContainer { Text(clubs.recoveryKey().orEmpty()) }
                Text("Save this key privately to restore your membership on another device.")
            }
            TextButton({ destructive = "Replace recovery key" }, enabled = !busy) { Text("Replace recovery key") }
            TextButton({ destructive = "Sign out" }, enabled = !busy) { Text("Sign out") }
            TextButton({ destructive = "Delete Clubs profile" }, enabled = !busy) { Text("Delete Clubs profile") }
            TextButton({ context.startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse("https://envemedia.com/community.html"))) }) { Text("Enve support") }
        }
    }, confirmButton = { TextButton(close) { Text("Done") } })
    destructive?.let { action ->
        ClubConfirm(action, "Save your recovery key if you plan to keep using this profile.", { destructive = null }) {
            destructive = null
            perform {
                when (action) {
                    "Replace recovery key" -> { clubs.replaceRecoveryKey(); showKey = false; showKey = true }
                    else -> { clubs.endSession(action == "Delete Clubs profile"); close() }
                }
            }
        }
    }
}

@Composable
private fun ClubRoom(clubs: ClubsFacade, id: String, member: ClubAccount, books: List<Book>, onBack: () -> Unit, onOpenBook: (Book, Long?) -> Unit, onFindPassage: (Book, String) -> Unit) {
    val palette = Hearth.palette
    val scope = rememberCoroutineScope()
    val copies by clubs.copies.collectAsState()
    val reminders by clubs.reminders.collectAsState()
    var club by remember { mutableStateOf<ClubDetails?>(null) }
    var reading by remember { mutableStateOf<ClubReadDetails?>(null) }
    var archived by remember { mutableStateOf<ClubRead?>(null) }
    var thread by remember { mutableStateOf<Discussion?>(null) }
    var next by remember { mutableStateOf<ClubNextUp?>(null) }
    var page by remember { mutableStateOf("Now Reading") }
    var editor by remember { mutableStateOf<Editor?>(null) }
    var invitation by remember { mutableStateOf<ClubInvite?>(null) }
    var confirm by remember { mutableStateOf<Confirmation?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val host = club?.ownerID == member.id
    val requestReminders = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { approved ->
        if (approved) reading?.let { clubs.setReminders(id, it, true) }
        else error = "Allow notifications in Settings to get reading reminders."
    }

    suspend fun reload() {
        val result = clubs.club(id)
        club = result
        val selectedRead = archived ?: result.current
        reading = selectedRead?.let { clubs.read(id, it.id) }
        if (page == "Next Up") next = clubs.nextUp(id)
    }

    fun perform(action: suspend () -> Unit) {
        if (busy) return
        busy = true
        error = null
        scope.launch {
            try { action(); reload() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { error = failure.message ?: "Book Clubs is temporarily unavailable." }
            finally { busy = false }
        }
    }

    LaunchedEffect(id, page, archived?.id) {
        while (true) {
            if (!busy) {
                try { reload(); error = null }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) { club = null; reading = null; next = null; error = failure.message }
            }
            delay(25_000)
        }
    }
    BackHandler {
        when { thread != null -> thread = null; archived != null -> archived = null; else -> onBack() }
    }
    val room = club
    val details = reading
    val conversation = thread
    if (conversation != null && room != null) {
        ClubDiscussion(clubs, room, member, conversation, books.firstOrNull { it.uniqueKey == copies[conversation.read.id] },
            onBack = { thread = null }, onOpenBook = onOpenBook, onFindPassage = onFindPassage)
        return
    }

    ClubPage(room?.name ?: "Book Club", if (archived == null) onBack else ({ archived = null })) {
        if (room != null) {
            if (archived == null) {
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    listOf("Now Reading", "Activity", "Next Up", "History").forEach { name ->
                        FilterChip(selected = page == name, onClick = { page = name }, label = { Text(name) })
                    }
                }
            }
            when (if (archived != null) "Now Reading" else page) {
                "Activity" -> room.activity.forEach { entry ->
                    val name = entry.memberName ?: "A member"
                    val label = when (entry.kind) {
                        "checkpoint" -> "$name reached ${entry.label}"
                        "readStarted" -> "$name started ${entry.label}"
                        "pollClosed" -> "$name closed the vote for ${entry.label}"
                        else -> "$name updated the reading plan"
                    }
                    Text(label, color = palette.text)
                    Text(showDate(entry.createdAt), color = palette.textSecondary, fontSize = 12.sp)
                    HorizontalDivider()
                }
                "History" -> room.reads.filter { it.closedAt != null }.forEach { read ->
                    TextButton({ archived = read }) { Text(read.title) }
                }
                "Next Up" -> next?.let { recommendations ->
                    ClubNextPage(recommendations, member, host,
                        onNominate = { editor = Editor.Nominate }, onPoll = { editor = Editor.Poll(recommendations.nominations) },
                        vote = { poll, choice -> perform { clubs.vote(id, poll.id, choice.id) } },
                        close = { poll, winner -> perform { clubs.closePoll(id, poll.id, winner) } },
                        start = { poll, winner -> editor = Editor.Start(poll, winner) })
                }
                else -> {
                    if (details != null && details.read.id == (archived ?: room.current)?.id) {
                        val copy = books.firstOrNull { it.uniqueKey == copies[details.read.id] }
                        ReadBoard(room, details, member, copy, host,
                            onOpenBook = { onOpenBook(it, null) }, onPick = { editor = Editor.Copy(details) },
                            reminders = id in reminders, onRemind = { enabled ->
                                if (enabled && Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                                    requestReminders.launch(Manifest.permission.POST_NOTIFICATIONS)
                                } else clubs.setReminders(id, details, enabled)
                            },
                            onUnlink = { confirm = Confirmation("Unlink copy", "Your shared position will be removed.") { clubs.linkCopy(id, details, null) } },
                            onShare = { enabled, presence ->
                                if (enabled && details.sharing?.epoch == null) {
                                    confirm = Confirmation("Share progress?", "Anyone in this club can see your approximate position and checkpoints.") {
                                        clubs.shareProgress(id, details.read.id, true, presence)
                                    }
                                } else perform { clubs.shareProgress(id, details.read.id, enabled, presence) }
                            },
                            onComplete = { checkpoint -> confirm = Confirmation("Mark ${checkpoint.label} complete?", "This check-in is visible to the club.") {
                                clubs.complete(id, details.read.id, checkpoint.id)
                            } },
                            onEdit = { editor = Editor.Checkpoint(details.read.id, it) },
                            onDiscuss = { checkpoint, seen -> thread = Discussion(details.read, checkpoint, seen) })
                    } else if (room.current == null && archived == null) Text("The club hasn’t started a book yet.", color = palette.textSecondary)
                    if (archived == null) {
                        HorizontalDivider()
                        Text("Members", color = palette.text, fontSize = 21.sp, fontWeight = FontWeight.SemiBold)
                        room.members.forEach { person ->
                            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                                Text(person.name + if (person.id == room.ownerID) " · Host" else "", modifier = Modifier.weight(1f), color = palette.text)
                                if (person.id != member.id) TextButton({ editor = Editor.Member(person) }) { Text("Actions") }
                            }
                        }
                        if (host) {
                            Row(Modifier.horizontalScroll(rememberScrollState())) {
                                TextButton({ editor = Editor.Start(null, null) }) { Text("Start a Read") }
                                TextButton({ editor = Editor.Invite }) { Text("Invite Members") }
                                TextButton({ confirm = Confirmation("Delete club?", "This removes the club’s shared plan and history for everyone.") { clubs.leave(id, true); onBack() } }) { Text("Delete Club") }
                            }
                        } else TextButton({ confirm = Confirmation("Leave club?", "You’ll lose access to the plan and discussions.") { clubs.leave(id, false); onBack() } }) { Text("Leave Club") }
                    }
                }
            }
        }
        error?.let { Text(it, color = palette.textSecondary); TextButton({ perform {} }) { Text("Try Again") } }
    }

    when (val selected = editor) {
        is Editor.Start -> ClubPlanForm("Start a Read", null, nomination = selected.nomination, onCancel = { editor = null }) { _, source ->
            val draft = source ?: return@ClubPlanForm
            perform { clubs.startRead(id, draft.copy(pollID = selected.poll?.id)); archived = null; page = "Now Reading"; editor = null }
        }
        is Editor.Copy -> ClubCopyDialog(books, selected.read.read.title, { editor = null }) { book ->
            perform { clubs.linkCopy(id, selected.read, book); editor = null }
        }
        is Editor.Checkpoint -> ClubCheckpointDialog(selected.current, { editor = null }) { draft ->
            perform { clubs.setCheckpoint(id, selected.read, selected.current?.id, draft); editor = null }
        }
        Editor.Nominate -> ClubNominationDialog({ editor = null }) { title, author ->
            perform { clubs.nominate(id, title, author); editor = null }
        }
        is Editor.Poll -> ClubPollDialog(selected.nominations, { editor = null }) { title, options, due ->
            perform { clubs.startPoll(id, title, options, due); editor = null }
        }
        Editor.Invite -> AlertDialog(onDismissRequest = { editor = null }, title = { Text("Private invitation") }, text = {
            Column {
                invitation?.let { invite ->
                    Text(invite.code.chunked(5).joinToString("-"), fontWeight = FontWeight.SemiBold)
                    Text("Expires ${showDate(invite.expiresAt)}")
                    TextButton({
                        val text = "Join my Enve book club: ${clubs.inviteLink(invite.code)}\nCode: ${invite.code}"
                        context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null))
                    }) { Text("Share Invitation") }
                }
                TextButton({ perform { invitation = clubs.invite(id) } }, enabled = !busy) {
                    Text(if (invitation == null) "Generate Invite Code" else "Replace Invite Code")
                }
                TextButton({ perform { clubs.revokeInvite(id); invitation = null } }, enabled = !busy) { Text("Revoke Invitation") }
            }
        }, confirmButton = { TextButton({ editor = null }) { Text("Done") } })
        is Editor.Member -> AlertDialog({ editor = null }, title = { Text(selected.account.name) }, text = {
            val person = selected.account
            val blocked = person.id in club?.blockedIDs.orEmpty()
            Column {
                TextButton({ perform { clubs.block(person.id, !blocked); editor = null } }) { Text(if (blocked) "Unblock" else "Block") }
                if (host) {
                    TextButton({ editor = null; confirm = Confirmation("Transfer hosting?", "${person.name} will manage invitations and membership.") { clubs.transfer(id, person.id) } }) { Text("Transfer Hosting") }
                    TextButton({ editor = null; confirm = Confirmation("Remove ${person.name}?", "This member will lose access to discussions and invitations.") { clubs.remove(id, person.id) } }) { Text("Remove Member") }
                }
            }
        }, confirmButton = { TextButton({ editor = null }) { Text("Done") } })
        null -> Unit
    }
    confirm?.let { action -> ClubConfirm(action.title, action.detail, { confirm = null }) { confirm = null; perform(action.apply) } }
}

private sealed interface Editor {
    data class Start(val poll: ClubPoll?, val nomination: ClubNomination?) : Editor
    data class Copy(val read: ClubReadDetails) : Editor
    data class Checkpoint(val read: String, val current: ClubCheckpoint?) : Editor
    data class Member(val account: ClubAccount) : Editor
    data class Poll(val nominations: List<ClubNomination>) : Editor
    data object Nominate : Editor
    data object Invite : Editor
}

private data class Confirmation(val title: String, val detail: String, val apply: suspend () -> Unit)
internal data class Discussion(val read: ClubRead, val checkpoint: ClubCheckpoint?, val seen: Boolean)

@Composable
private fun ReadBoard(club: ClubDetails, read: ClubReadDetails, account: ClubAccount, book: Book?, host: Boolean,
                      onOpenBook: (Book) -> Unit, onPick: () -> Unit, onUnlink: () -> Unit,
                      onShare: (Boolean, Boolean) -> Unit, onComplete: (ClubCheckpoint) -> Unit,
                      reminders: Boolean, onRemind: (Boolean) -> Unit,
                      onEdit: (ClubCheckpoint?) -> Unit, onDiscuss: (ClubCheckpoint?, Boolean) -> Unit) {
    val palette = Hearth.palette
    val active = read.read.closedAt == null
    Text(read.read.title, color = palette.text, fontSize = 29.sp, fontWeight = FontWeight.SemiBold)
    read.read.author?.let { Text(it, color = palette.textSecondary) }
    if (book != null) {
        Button({ onOpenBook(book) }) { Text(if (book.mediaType == AppMediaType.EBOOK) "Continue Reading" else "Continue Listening") }
    }
    if (active) {
        Row(Modifier.horizontalScroll(rememberScrollState())) {
            TextButton(onPick) { Text(if (book == null) "Choose My Copy" else "Change Copy") }
            if (book != null) TextButton(onUnlink) { Text("Unlink Copy") }
        }
        if (book != null) {
            val sharing = read.sharing?.epoch != null
            ClubToggle("Share my progress", sharing) { onShare(it, false) }
            if (sharing) ClubToggle("Show when I’m reading", read.sharing?.presence == true) { onShare(true, it) }
        }
        if (read.checkpoints.any { it.dueAt != null }) ClubToggle("Checkpoint reminders", reminders, onRemind)
    }
    HorizontalDivider()
    Text("The Track", color = palette.text, fontSize = 21.sp, fontWeight = FontWeight.SemiBold)
    club.members.forEach { person ->
        val position = read.progress.firstOrNull { it.accountID == person.id }
        val completed = read.completions.filter { it.accountID == person.id }.map { it.checkpointID }.toSet()
        val last = read.checkpoints.lastOrNull { it.id in completed }
        val next = read.checkpoints.firstOrNull { it.id !in completed }
        Text(person.name + (if (person.id == account.id) " (you)" else ""), color = palette.text, fontWeight = FontWeight.SemiBold)
        val percentage = position?.fraction ?: last?.trackPosition
        if (percentage != null) LinearProgressIndicator(progress = { percentage.toFloat() }, modifier = Modifier.fillMaxWidth(), color = palette.ember)
        val status = listOfNotNull(
            position?.let { "About ${(it.fraction * 100).toInt()}%" },
            last?.let { "Reached ${it.label}" },
            when {
                next?.dueAt?.let { it < System.currentTimeMillis() } == true -> "Catching up"
                next == null && completed.isNotEmpty() -> "Plan complete"
                last?.dueAt?.let { it > System.currentTimeMillis() } == true -> "Ahead"
                next?.dueAt != null -> "On track"
                else -> null
            },
            if (position?.activeUntil?.let { it > System.currentTimeMillis() } == true) "Reading now" else null,
        )
        Text(status.joinToString(" · ").ifBlank { "No check-in yet" }, color = palette.textSecondary, fontSize = 13.sp)
    }
    HorizontalDivider()
    Text("Reading Plan", color = palette.text, fontSize = 21.sp, fontWeight = FontWeight.SemiBold)
    TextButton({ onDiscuss(null, true) }) { Text("General Discussion") }
    read.checkpoints.forEach { checkpoint ->
        val done = read.completions.any { it.accountID == account.id && it.checkpointID == checkpoint.id }
        Text(checkpoint.label, color = palette.text, fontWeight = FontWeight.SemiBold)
        checkpoint.dueAt?.let { Text(showDate(it), color = palette.textSecondary) }
        Row(Modifier.horizontalScroll(rememberScrollState())) {
            TextButton({ onDiscuss(checkpoint, done) }) { Text("Discuss") }
            if (active && !done) TextButton({ onComplete(checkpoint) }) { Text("Mark Complete") }
            if (active && host) TextButton({ onEdit(checkpoint) }) { Text("Edit") }
        }
    }
    if (active && host) TextButton({ onEdit(null) }) { Text("Add Checkpoint") }
}

@Composable
internal fun ClubPage(title: String, onBack: () -> Unit, body: @Composable () -> Unit) {
    val palette = Hearth.palette
    Box(Modifier.fillMaxSize().background(palette.bg).statusBarsPadding().navigationBarsPadding()) {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            TextButton(onBack) { Text("Back") }
            Text(title, color = palette.text, fontSize = 32.sp, fontWeight = FontWeight.SemiBold)
            body()
        }
    }
}

@Composable
internal fun ClubToggle(label: String, value: Boolean, change: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = Hearth.palette.text, modifier = Modifier.weight(1f))
        Switch(value, change)
    }
}

@Composable
internal fun ClubConfirm(title: String, message: String, cancel: () -> Unit, accept: () -> Unit) {
    AlertDialog(onDismissRequest = cancel, title = { Text(title) }, text = { Text(message) },
        confirmButton = { TextButton(accept) { Text("Confirm") } }, dismissButton = { TextButton(cancel) { Text("Cancel") } })
}

@Composable
internal fun ClubInput(title: String, label: String, initial: String = "", close: () -> Unit, button: String = "Save", submit: (String) -> Unit) {
    var value by remember { mutableStateOf(initial) }
    AlertDialog(onDismissRequest = close, title = { Text(title) }, text = {
        OutlinedTextField(value, { value = it }, label = { Text(label) }, modifier = Modifier.fillMaxWidth())
    }, confirmButton = { TextButton({ submit(value.trim()) }, enabled = value.isNotBlank()) { Text(button) } },
        dismissButton = { TextButton(close) { Text("Cancel") } })
}

internal fun showDate(value: Long): String = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(value))
internal fun chapterKey(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFD)
    .replace(Regex("\\p{M}+"), "").lowercase(Locale.ROOT).split(Regex("[^\\p{L}\\p{N}]+")).filter(String::isNotEmpty).joinToString(" ")
