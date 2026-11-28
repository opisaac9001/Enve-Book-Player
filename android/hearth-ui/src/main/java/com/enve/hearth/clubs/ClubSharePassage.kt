package com.enve.hearth.clubs

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.FilterChip
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.enve.engine.clubs.ClubReadDetails
import com.enve.engine.clubs.ClubSummary
import com.enve.engine.clubs.ClubsFacade
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable
fun ClubSharePassage(clubs: ClubsFacade, bookKey: String, quote: String, chapter: String?, close: () -> Unit) {
    var candidates by remember { mutableStateOf(emptyList<Pair<ClubSummary, ClubReadDetails>>()) }
    var selectedClub by remember { mutableStateOf<String?>(null) }
    var selectedThread by remember { mutableStateOf<String?>(null) }
    var excerpt by remember { mutableStateOf(quote.take(600)) }
    var comment by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val plan = candidates.firstOrNull { it.first.id == selectedClub }?.second

    LaunchedEffect(bookKey) {
        try {
            candidates = clubs.clubs().filter { it.currentTitle != null }.mapNotNull { summary ->
                val read = clubs.club(summary.id).current ?: return@mapNotNull null
                if (clubs.copies.value[read.id] != bookKey) return@mapNotNull null
                summary to clubs.read(summary.id, read.id)
            }
            selectedClub = candidates.firstOrNull()?.first?.id
            if (candidates.isEmpty()) error = "Link this copy to a club’s current read before sharing."
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            error = failure.message
        }
    }
    LaunchedEffect(plan?.read?.id) {
        selectedThread = chapter?.let { title ->
            val key = chapterKey(title)
            plan?.checkpoints?.firstOrNull { it.chapterKey == key || chapterKey(it.label) == key }?.id
        }
    }
    AlertDialog(onDismissRequest = close, title = { Text("Share with a Club") }, text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            OutlinedTextField(excerpt, { excerpt = it }, label = { Text("Passage") }, minLines = 2, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(comment, { comment = it }, label = { Text("Comment (optional)") }, modifier = Modifier.fillMaxWidth())
            candidates.forEach { (summary, _) ->
                FilterChip(summary.id == selectedClub, { selectedClub = summary.id }, label = { Text(summary.name) })
            }
            if (plan != null) {
                FilterChip(selectedThread == null, { selectedThread = null }, label = { Text("General Discussion") })
                plan.checkpoints.forEach { checkpoint ->
                    FilterChip(selectedThread == checkpoint.id, { selectedThread = checkpoint.id }, label = { Text(checkpoint.label) })
                }
                if (selectedThread == null) Text("General discussion is visible immediately. Choose a checkpoint to hide spoilers.")
            }
            error?.let { Text(it) }
        }
    }, confirmButton = {
        TextButton({
            val id = selectedClub ?: return@TextButton
            val read = plan ?: return@TextButton
            busy = true
            scope.launch {
                try {
                    clubs.post(id, read.read.id, selectedThread, comment, excerpt.trim(), chapter, null)
                    close()
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Exception) {
                    error = failure.message
                } finally {
                    busy = false
                }
            }
        }, enabled = plan != null && !busy && excerpt.isNotBlank() && excerpt.length <= 600 && comment.length <= 3000) { Text("Share") }
    }, dismissButton = { TextButton(close) { Text("Cancel") } })
}
