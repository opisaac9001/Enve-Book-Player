package com.enve.hearth.clubs

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
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
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.Book
import com.enve.engine.clubs.ClubAccount
import com.enve.engine.clubs.ClubDetails
import com.enve.engine.clubs.ClubPost
import com.enve.engine.clubs.ClubsFacade
import com.enve.hearth.design.Hearth
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

private val reactions = listOf("\u2764\ufe0f", "\ud83d\ude02", "\ud83d\ude2e", "\ud83d\udc4f", "\ud83d\udcda")

@Composable
internal fun ClubDiscussion(clubs: ClubsFacade, club: ClubDetails, member: ClubAccount, discussion: Discussion, book: Book?,
                            onBack: () -> Unit, onOpenBook: (Book, Long?) -> Unit, onFindPassage: (Book, String) -> Unit) {
    val palette = Hearth.palette
    val scope = rememberCoroutineScope()
    val read = discussion.read.id
    val checkpoint = discussion.checkpoint?.id
    var visible by remember { mutableStateOf(discussion.seen) }
    var archived by remember { mutableStateOf(discussion.read.closedAt != null) }
    var posts by remember { mutableStateOf<List<ClubPost>>(emptyList()) }
    var pages by remember { mutableStateOf(1) }
    var next by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var composing by remember { mutableStateOf(false) }
    var parent by remember { mutableStateOf<ClubPost?>(null) }
    var report by remember { mutableStateOf<ClubPost?>(null) }
    var removing by remember { mutableStateOf<ClubPost?>(null) }
    var busy by remember { mutableStateOf(false) }
    var reported by remember { mutableStateOf(false) }

    suspend fun reload() {
        val loaded = mutableListOf<ClubPost>()
        var cursor: String? = null
        for (page in 0 until pages) {
            val result = clubs.posts(club.id, read, checkpoint, cursor)
            loaded += result.posts
            cursor = result.before
            archived = result.archived
            if (cursor == null) break
        }
        posts = loaded.distinctBy(ClubPost::id)
        next = cursor
    }

    fun perform(action: suspend () -> Unit) {
        if (busy) return
        busy = true
        scope.launch {
            try { action(); reload(); error = null }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Exception) { error = failure.message }
            finally { busy = false }
        }
    }

    LaunchedEffect(visible) {
        if (!visible) return@LaunchedEffect
        while (true) {
            if (!busy) {
                try { reload(); error = null }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (failure: Exception) { error = failure.message; posts = emptyList(); next = null }
            }
            delay(20_000)
        }
    }

    BackHandler(onBack = onBack)
    ClubPage(discussion.checkpoint?.label ?: "General Discussion", onBack) {
        if (!visible) {
            Text("Spoilers ahead", color = palette.text, fontWeight = FontWeight.SemiBold)
            Text("This discussion may reveal events through this checkpoint.", color = palette.textSecondary)
            Button({ visible = true }) { Text("Reveal Spoilers") }
        } else {
            if (!archived) Button({ parent = null; composing = true }) { Text("Write a Post") }
            if (reported) Text("Report sent.", color = palette.textSecondary)
            posts.forEach { post ->
                HorizontalDivider()
                Text(post.authorName, color = palette.text, fontWeight = FontWeight.SemiBold)
                Text(showDate(post.createdAt), color = palette.textSecondary, fontSize = 12.sp)
                if (post.parentID != null) {
                    val original = posts.firstOrNull { it.id == post.parentID }
                    Text(original?.let { "Reply to ${it.authorName}" } ?: "Reply", color = palette.textSecondary)
                }
                if (post.body.isNotBlank()) Text(post.body, color = palette.text)
                post.passage?.let { passage ->
                    Text(passage, color = palette.text, fontStyle = FontStyle.Italic)
                    post.passageChapter?.let { Text(it, color = palette.textSecondary) }
                    if (book?.mediaType == AppMediaType.EBOOK) {
                        TextButton({ onFindPassage(book, passage) }) { Text("Find in My Copy") }
                    }
                    if (book?.mediaType == AppMediaType.AUDIOBOOK) {
                        val chapter = post.passageChapter?.let { name -> book.chapters.singleOrNull { chapterKey(it.title) == chapterKey(name) } }
                        chapter?.let { TextButton({ onOpenBook(book, it.startTime) }) { Text("Play This Chapter") } }
                    }
                }
                Row(Modifier.horizontalScroll(rememberScrollState())) {
                    reactions.forEach { emoji ->
                        val votes = post.reactions.filter { it.emoji == emoji }
                        val mine = votes.any { it.accountID == member.id }
                        FilterChip(mine, { perform { clubs.react(club.id, read, post.id, emoji, !mine) } }, enabled = !busy,
                            label = { Text(if (votes.isEmpty()) emoji else "$emoji ${votes.size}") })
                    }
                }
                Row(Modifier.horizontalScroll(rememberScrollState())) {
                    if (!archived) TextButton({ parent = post; composing = true }) { Text("Reply") }
                    if (post.authorID != member.id) TextButton({ report = post }) { Text("Report") }
                    if (post.authorID == member.id || club.ownerID == member.id) TextButton({ removing = post }) { Text("Delete") }
                }
            }
            if (next != null) TextButton({ perform { pages += 1 } }, enabled = !busy) { Text("Load Older Posts") }
        }
        error?.let { Text(it, color = palette.textSecondary) }
    }
    if (composing) ClubPostDialog(parent, discussion.checkpoint?.label, close = { composing = false }) { body, passage, chapter ->
        perform {
            clubs.post(club.id, read, checkpoint, body, passage, chapter, parent?.id)
            composing = false
        }
    }
    report?.let { post -> ClubInput("Report Post", "Reason", close = { report = null }) { reason ->
        perform { clubs.report(club.id, read, post.id, reason); report = null; reported = true }
    } }
    removing?.let { post -> ClubConfirm("Delete post?", "This removes the post from the club.", { removing = null }) {
        perform { clubs.deletePost(club.id, read, post.id); removing = null }
    } }
}

@Composable
private fun ClubPostDialog(parent: ClubPost?, checkpoint: String?, close: () -> Unit, save: (String, String?, String?) -> Unit) {
    var text by remember { mutableStateOf("") }
    var share by remember { mutableStateOf(false) }
    var excerpt by remember { mutableStateOf("") }
    var chapter by remember { mutableStateOf(checkpoint.orEmpty()) }
    AlertDialog(onDismissRequest = close, title = { Text(parent?.let { "Reply to ${it.authorName}" } ?: "New post") }, text = {
        Column {
            OutlinedTextField(text, { text = it }, label = { Text("Write a thought or question") }, minLines = 2, modifier = Modifier.fillMaxWidth())
            ClubToggle("Share a short passage", share) { share = it }
            if (share) {
                OutlinedTextField(excerpt, { excerpt = it }, label = { Text("Excerpt") }, minLines = 2, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(chapter, { chapter = it }, label = { Text("Chapter (optional)") }, modifier = Modifier.fillMaxWidth())
            }
        }
    }, confirmButton = {
        TextButton({ save(text.trim(), excerpt.trim().takeIf { share && it.isNotEmpty() }, chapter.trim().takeIf(String::isNotEmpty)) },
            enabled = (text.isNotBlank() || share && excerpt.isNotBlank()) && text.length <= 3000 && (!share || excerpt.length <= 600)) { Text("Post") }
    }, dismissButton = { TextButton(close) { Text("Cancel") } })
}
