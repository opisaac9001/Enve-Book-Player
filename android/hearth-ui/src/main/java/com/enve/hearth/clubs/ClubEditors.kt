package com.enve.hearth.clubs

import android.app.DatePickerDialog
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.enve.core.data.model.Book
import com.enve.engine.clubs.ClubAccount
import com.enve.engine.clubs.ClubCheckpoint
import com.enve.engine.clubs.ClubCheckpointDraft
import com.enve.engine.clubs.ClubNextUp
import com.enve.engine.clubs.ClubNomination
import com.enve.engine.clubs.ClubPoll
import com.enve.engine.clubs.ClubReadDraft
import com.enve.hearth.design.Hearth
import java.time.LocalDate
import java.time.ZoneId

@Composable
internal fun ClubPlanForm(title: String, book: Book?, clubNameRequired: Boolean = false, nomination: ClubNomination? = null,
                          onCancel: () -> Unit, save: (String, ClubReadDraft?) -> Unit) {
    var clubName by remember { mutableStateOf("") }
    var bookTitle by remember { mutableStateOf(nomination?.name ?: book?.title.orEmpty()) }
    var author by remember { mutableStateOf(nomination?.author ?: book?.author.orEmpty()) }
    val checkpoints = remember {
        mutableStateListOf<ClubCheckpointDraft>().apply {
            val chapters = book?.chapters.orEmpty().filter { it.title.isNotBlank() }
            if (chapters.isEmpty() && book != null) add(ClubCheckpointDraft("Finish the book", trackPosition = 1.0))
            else if (chapters.isNotEmpty() && book != null) {
                val count = minOf(4, chapters.size)
                repeat(count) { index ->
                    val chapter = chapters[((index + 1) * chapters.size + count - 1) / count - 1]
                    add(ClubCheckpointDraft(chapter.title, chapterKey(chapter.title),
                        trackPosition = (chapter.endTime.toDouble() / book.duration).takeIf { it in 0.0..1.0 }))
                }
            }
        }
    }
    AlertDialog(onDismissRequest = onCancel, title = { Text(title) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (clubNameRequired) OutlinedTextField(clubName, { clubName = it }, label = { Text("Club name") }, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(bookTitle, { bookTitle = it }, label = { Text(if (clubNameRequired) "First book (optional)" else "Book title") },
                enabled = book == null && nomination == null, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(author, { author = it }, label = { Text("Author") }, enabled = book == null && nomination == null, modifier = Modifier.fillMaxWidth())
            if (bookTitle.isNotBlank()) {
                checkpoints.forEachIndexed { index, draft ->
                    HorizontalDivider()
                    CheckpointFields(draft) { checkpoints[index] = it }
                    TextButton({ checkpoints.removeAt(index) }) { Text("Remove Checkpoint") }
                }
                TextButton({ checkpoints.add(ClubCheckpointDraft("")) }, enabled = checkpoints.size < 24) { Text("Add Checkpoint") }
            }
        }
    }, confirmButton = {
        TextButton({
            val draft = bookTitle.trim().takeIf(String::isNotEmpty)?.let { value ->
                ClubReadDraft(value, author.trim().takeIf(String::isNotEmpty), book?.seriesName,
                    checkpoints.map { it.copy(label = it.label.trim(), chapterKey = it.chapterKey ?: chapterKey(it.label)) })
            }
            save(clubName.trim(), draft)
        }, enabled = (if (clubNameRequired) clubName.isNotBlank() else bookTitle.isNotBlank()) && checkpoints.none { it.label.isBlank() }) {
            Text(if (clubNameRequired) "Create" else "Start")
        }
    }, dismissButton = { TextButton(onCancel) { Text("Cancel") } })
}

@Composable
internal fun ClubCheckpointDialog(checkpoint: ClubCheckpoint?, close: () -> Unit, submit: (ClubCheckpointDraft) -> Unit) {
    var draft by remember { mutableStateOf(ClubCheckpointDraft(checkpoint?.label.orEmpty(), checkpoint?.chapterKey, checkpoint?.dueAt, checkpoint?.trackPosition)) }
    AlertDialog(onDismissRequest = close, title = { Text(if (checkpoint == null) "Add Checkpoint" else "Edit Checkpoint") },
        text = { Column { CheckpointFields(draft) { draft = it } } },
        confirmButton = { TextButton({ submit(draft.copy(label = draft.label.trim(), chapterKey = draft.chapterKey ?: chapterKey(draft.label))) }, enabled = draft.label.isNotBlank()) { Text("Save") } },
        dismissButton = { TextButton(close) { Text("Cancel") } })
}

@Composable
private fun CheckpointFields(draft: ClubCheckpointDraft, change: (ClubCheckpointDraft) -> Unit) {
    OutlinedTextField(draft.label, { change(draft.copy(label = it)) }, label = { Text("Checkpoint name") }, modifier = Modifier.fillMaxWidth())
    ClubDate(draft.dueAt, "Set Deadline") { change(draft.copy(dueAt = it)) }
}

@Composable
private fun ClubDate(selected: Long?, label: String, change: (Long?) -> Unit) {
    val context = LocalContext.current
    val zone = ZoneId.systemDefault()
    Row {
        TextButton({
            val start = if (selected == null) LocalDate.now().plusDays(7) else java.time.Instant.ofEpochMilli(selected).atZone(zone).toLocalDate()
            DatePickerDialog(context, { _, year, month, day ->
                change(LocalDate.of(year, month + 1, day).atTime(23, 59).atZone(zone).toInstant().toEpochMilli())
            }, start.year, start.monthValue - 1, start.dayOfMonth).show()
        }) { Text(selected?.let(::showDate) ?: label) }
        if (selected != null) TextButton({ change(null) }) { Text("Clear") }
    }
}

@Composable
internal fun ClubCopyDialog(books: List<Book>, suggestedTitle: String, close: () -> Unit, link: (Book) -> Unit) {
    var query by remember { mutableStateOf(suggestedTitle) }
    val safe = remember(books, query) {
        books.asSequence().filter { it.title.contains(query, ignoreCase = true) || it.author?.contains(query, ignoreCase = true) == true }.take(35).toList()
    }
    AlertDialog(onDismissRequest = close, title = { Text("Choose Your Copy") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            OutlinedTextField(query, { query = it }, label = { Text("Title or author") })
            if (safe.isEmpty()) Text("No matching book. Search another title or check in manually.")
            safe.forEach { book ->
                TextButton({ link(book) }) { Text(listOfNotNull(book.title, book.author).joinToString(" · ")) }
            }
        }
    }, confirmButton = { TextButton(close) { Text("Cancel") } })
}

@Composable
internal fun ClubNominationDialog(onCancel: () -> Unit, save: (String, String?) -> Unit) {
    var title by remember { mutableStateOf("") }
    var author by remember { mutableStateOf("") }
    AlertDialog(onDismissRequest = onCancel, title = { Text("Nominate a Book") }, text = {
        Column {
            OutlinedTextField(title, { title = it }, label = { Text("Book title") })
            OutlinedTextField(author, { author = it }, label = { Text("Author (optional)") })
        }
    }, confirmButton = { TextButton({ save(title.trim(), author.trim().takeIf(String::isNotEmpty)) }, enabled = title.isNotBlank()) { Text("Nominate") } },
        dismissButton = { TextButton(onCancel) { Text("Cancel") } })
}

@Composable
internal fun ClubPollDialog(nominations: List<ClubNomination>, close: () -> Unit, submit: (String, List<String>, Long?) -> Unit) {
    var title by remember { mutableStateOf("Next club read") }
    var date by remember { mutableStateOf<Long?>(null) }
    var selected by remember { mutableStateOf<Set<String>>(emptySet()) }
    AlertDialog(onDismissRequest = close, title = { Text("Start a Vote") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            OutlinedTextField(title, { title = it }, label = { Text("Name") })
            ClubDate(date, "Set Closing Date") { date = it }
            nominations.forEach { nominee ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(nominee.id in selected, { enabled -> selected = if (enabled) selected + nominee.id else selected - nominee.id },
                        enabled = nominee.id in selected || selected.size < 12)
                    Text(nominee.name)
                }
            }
        }
    }, confirmButton = { TextButton({ submit(title.trim(), selected.toList(), date) }, enabled = title.isNotBlank() && selected.size >= 2) { Text("Start") } },
        dismissButton = { TextButton(close) { Text("Cancel") } })
}

@Composable
internal fun ClubNextPage(next: ClubNextUp, account: ClubAccount, isHost: Boolean, onNominate: () -> Unit, onPoll: () -> Unit,
                          vote: (ClubPoll, ClubNomination) -> Unit, close: (ClubPoll, String?) -> Unit, start: (ClubPoll, ClubNomination) -> Unit) {
    val palette = Hearth.palette
    var choosing by remember { mutableStateOf<ClubPoll?>(null) }
    TextButton(onNominate) { Text("Nominate a Book") }
    if (isHost && next.nominations.size >= 2 && next.polls.none { it.closedAt == null }) TextButton(onPoll) { Text("Start a Vote") }
    next.polls.forEach { poll ->
        HorizontalDivider()
        Text(poll.name, color = palette.text, fontWeight = FontWeight.SemiBold)
        if (poll.closedAt == null) poll.closesAt?.let { Text("Closes ${showDate(it)}", color = palette.textSecondary) }
        val open = poll.closedAt == null && (poll.closesAt?.let { it > System.currentTimeMillis() } ?: true)
        next.nominations.filter { it.id in poll.optionIDs }.forEach { option ->
            val votes = poll.votes.filter { it.nominationID == option.id }
            if (open) FilterChip(votes.any { it.accountID == account.id }, { vote(poll, option) }, label = { Text(option.name) })
            else Text(option.name + if (poll.winnerID == option.id) " · Winner" else "", color = palette.text)
            Text(votes.map { it.memberName }.sorted().joinToString(", ").ifEmpty { "No votes yet" }, color = palette.textSecondary)
        }
        if (isHost && poll.closedAt == null) TextButton({ choosing = poll }) { Text("Close Vote") }
        if (isHost && poll.closedAt != null && poll.startedReadID == null) {
            next.nominations.firstOrNull { it.id == poll.winnerID }?.let { winner ->
                TextButton({ start(poll, winner) }) { Text("Start Winning Book") }
            }
        }
    }
    HorizontalDivider()
    Text("Nominations", color = palette.text, fontWeight = FontWeight.SemiBold)
    next.nominations.forEach { nominee ->
        Text(listOfNotNull(nominee.name, nominee.author, nominee.memberName?.let { "Suggested by $it" }).joinToString(" · "), color = palette.textSecondary)
    }
    choosing?.let { poll ->
        val counts = poll.votes.groupingBy { it.nominationID }.eachCount()
        val high = counts.values.maxOrNull() ?: 0
        val leaders = next.nominations.filter { it.id in poll.optionIDs && counts.getOrDefault(it.id, 0) == high }
        if (leaders.size == 1) ClubConfirm("Close Vote?", "${leaders.single().name} has the most votes.", { choosing = null }) {
            choosing = null
            close(poll, null)
        } else AlertDialog(onDismissRequest = { choosing = null }, title = { Text("Break the tie") }, text = {
            Column {
                leaders.forEach { book -> TextButton({ choosing = null; close(poll, book.id) }) { Text(book.name) } }
            }
        }, confirmButton = { TextButton({ choosing = null }) { Text("Cancel") } })
    }
}
