package com.enve.app.clubs

import android.content.Context
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.enve.core.data.local.ProfileStorageLocations
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.concurrent.TimeUnit
import com.enve.core.auth.CredentialVault
import com.enve.core.data.model.Book
import com.enve.core.di.ApplicationScope
import com.enve.engine.clubs.*
import com.enve.engine.impl.BuildConfig
import com.enve.engine.playback.PlaybackFacade
import java.io.IOException
import java.text.Normalizer
import java.util.Locale
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.JsonPrimitive
import okhttp3.Call
import okhttp3.Callback
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response

@Singleton
class ClubsStore @Inject constructor(
    private val vault: CredentialVault,
    @ApplicationContext private val context: Context,
    private val storage: ProfileStorageLocations,
    @ApplicationScope private val scope: CoroutineScope,
    playback: PlaybackFacade,
) : ClubsFacade {
    private val endpoint = BuildConfig.ENVE_CLUBS_SERVICE_URL.toHttpUrlOrNull()?.takeIf {
        it.isHttps || BuildConfig.DEBUG && it.host in setOf("127.0.0.1", "localhost")
    }?.takeIf { it.username.isEmpty() && it.password.isEmpty() && it.query == null && it.fragment == null }
    private val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false).build()
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val credentialKey = "club_credentials_$endpoint"
    private var credentials = if (endpoint == null) null else vault.get(credentialKey)?.let { runCatching { json.decodeFromString<Credentials>(it) }.getOrNull() }
    private val _account = MutableStateFlow(credentials?.account)
    override val account = _account.asStateFlow()
    private var local = loadState()
    private val _copies = MutableStateFlow(local.copies.mapValues { it.value.bookKey })
    override val copies = _copies.asStateFlow()
    private val _reminders = MutableStateFlow(local.reminderClubs.toSet())
    override val reminders = _reminders.asStateFlow()
    private val scheduled = mutableMapOf<String, Map<String, Long>>()
    private val lastUpdates = mutableMapOf<String, Progress>()
    private val lastChapter = mutableMapOf<String, String>()
    private val lastWrites = mutableMapOf<String, Long>()
    override val available: Boolean get() = endpoint != null

    init {
        if (available) {
            scope.launch(Dispatchers.Main.immediate) {
                playback.transport.combine(playback.nowPlaying) { transport, now -> transport to now }.collect { (transport, now) ->
                    if (now != null && transport.hasMedia && transport.durationMs > 0 && transport.bookId == now.bookId) {
                        record(now.bookKey, transport.progress.toDouble(), transport.isPlaying, transport.durationMs)
                    }
                }
            }
            scope.launch(Dispatchers.Main.immediate) { while (true) { flush(); delay(12_000) } }
        }
    }

    override fun inviteLink(code: String): String = if (endpoint?.isHttps == true) {
        "https://envemedia.com/books/clubs/join/#code=$code"
    } else "enve-book://club/join?code=$code"

    override fun recoveryKey(): String? = credentials?.recoveryKey
    override suspend fun createProfile(name: String) = authorize("accounts", objectOf("name" to name))
    override suspend fun restoreProfile(key: String) = authorize("sessions", objectOf("recoveryKey" to key))

    private suspend fun authorize(path: String, body: JsonObject) {
        val loggedIn: Credentials = call(path, "POST", body, authenticated = false)
        vault.put(credentialKey, json.encodeToString(loggedIn))
        credentials = loggedIn
        _account.value = loggedIn.account
        local = loadState()
        refreshCopies()
        _reminders.value = local.reminderClubs.toSet()
    }

    override suspend fun replaceRecoveryKey() {
        val previous = credentials ?: return
        val result: Recovery = call("me/recovery", "POST")
        val updated = previous.copy(recoveryKey = result.recoveryKey)
        vault.put(credentialKey, json.encodeToString(updated))
        credentials = updated
    }

    override suspend fun endSession(delete: Boolean) {
        ok(if (delete) "me" else "me/session", "DELETE")
        local.reminderClubs.forEach(::cancelReminders)
        if (delete) vault.remove(stateKey)
        vault.remove(credentialKey)
        credentials = null
        _account.value = null
        local = LocalState()
        lastUpdates.clear()
        lastChapter.clear()
        lastWrites.clear()
        refreshCopies()
        _reminders.value = emptySet()
    }

    override suspend fun clubs(): List<ClubSummary> = call("clubs")
    override suspend fun createClub(name: String, read: ClubReadDraft?): String =
        call<ID>("clubs", "POST", buildJsonObject { put("name", name); if (read != null) put("read", json.encodeToJsonElement(ClubReadDraft.serializer(), read)) }).id
    override suspend fun join(code: String): String = call<ID>("clubs/join", "POST", objectOf("code" to code)).id
    override suspend fun club(id: String): ClubDetails = call("clubs/$id")
    override suspend fun invite(club: String): ClubInvite = call("clubs/$club/invite", "POST")
    override suspend fun revokeInvite(club: String) { ok("clubs/$club/invite", "DELETE") }
    override suspend fun leave(club: String, delete: Boolean) {
        if (delete) ok("clubs/$club", "DELETE") else ok("clubs/$club/leave", "POST")
        local.copies.values.filter { it.clubID == club }.forEach { copy ->
            local.copies.remove(copy.readID); local.pending.remove(copy.readID)
        }
        local.reminderClubs.remove(club)
        cancelReminders(club)
        _reminders.value = local.reminderClubs.toSet()
        save()
    }
    override suspend fun transfer(club: String, member: String) = ok("clubs/$club/host", "PUT", objectOf("memberID" to member))
    override suspend fun remove(club: String, member: String) = ok("clubs/$club/members/$member", "DELETE")
    override suspend fun block(member: String, enabled: Boolean) = ok("blocks/$member", if (enabled) "PUT" else "DELETE")
    override suspend fun read(club: String, read: String): ClubReadDetails = call<ClubReadDetails>(readPath(club, read)).also { details ->
        local.copies[read]?.let { copy ->
            val sharing = details.sharing?.takeIf { details.read.closedAt == null }
            if (copy.sharing?.epoch != sharing?.epoch) {
                local.pending.remove(read)
                lastUpdates.remove(read)
                lastChapter.remove(read)
            }
            val updated = copy.copy(
                sharing = sharing,
                checkpoints = details.checkpoints.map(ClubCheckpoint::id),
                checkpointNames = checkpointKeys(details),
            )
            if (updated != copy) {
                local.copies[read] = updated
                save()
            }
        }
        if (club in local.reminderClubs && details.read.closedAt == null) scheduleReminders(club, details)
    }
    override suspend fun startRead(club: String, draft: ClubReadDraft): String =
        call<ID>("clubs/$club/reads", "POST", json.encodeToJsonElement(ClubReadDraft.serializer(), draft)).id
    override suspend fun setCheckpoint(club: String, read: String, id: String?, checkpoint: ClubCheckpointDraft) {
        val path = readPath(club, read) + "/checkpoints"
        val body = json.encodeToJsonElement(ClubCheckpointDraft.serializer(), checkpoint)
        if (id == null) call<ID>(path, "POST", body) else ok("$path/$id", "PATCH", body)
    }
    override suspend fun complete(club: String, read: String, checkpoint: String) =
        ok(readPath(club, read) + "/checkpoints/$checkpoint/complete", "PUT", objectOf())

    override suspend fun linkCopy(club: String, read: ClubReadDetails, book: Book?) {
        val id = read.read.id
        val last = local.copies[id]
        if ((last?.bookKey != book?.uniqueKey || book == null) && read.sharing?.epoch != null) shareProgress(club, id, false, false)
        local.pending.remove(id)
        lastUpdates.remove(id)
        lastChapter.remove(id)
        if (book == null) local.copies.remove(id)
        else {
            val chapters = book.chapters.groupBy { normalizeChapter(it.title) }
            val ends = chapters.mapNotNull { (key, matches) ->
                val end = matches.singleOrNull()?.endTime ?: return@mapNotNull null
                if (book.duration > 0 && end in 1..book.duration) key to end.toDouble() / book.duration else null
            }
            local.copies[id] = Copy(
                club, id, book.uniqueKey, book.progress.toDouble(), ends.toMap(),
                read.checkpoints.map(ClubCheckpoint::id), checkpointKeys(read),
            )
        }
        save()
    }

    private fun checkpointKeys(read: ClubReadDetails): Map<String, String> =
        read.checkpoints.associate { it.id to (it.chapterKey ?: normalizeChapter(it.label)) }

    override fun setReminders(club: String, read: ClubReadDetails, enabled: Boolean) {
        if (enabled) {
            local.reminderClubs.add(club)
            scheduleReminders(club, read)
        } else {
            local.reminderClubs.remove(club)
            cancelReminders(club)
        }
        _reminders.value = local.reminderClubs.toSet()
        save()
    }

    private fun scheduleReminders(club: String, read: ClubReadDetails) {
        val me = _account.value?.id ?: return
        val complete = read.completions.filter { it.accountID == me }.map { it.checkpointID }.toSet()
        val now = System.currentTimeMillis()
        val upcoming = read.checkpoints.mapNotNull { checkpoint ->
            val due = checkpoint.dueAt ?: return@mapNotNull null
            if (checkpoint.id in complete || due <= now) return@mapNotNull null
            val early = due - 3_600_000
            checkpoint.id to if (early > now) early else due
        }.toMap()
        if (scheduled[club] == upcoming) return
        val manager = WorkManager.getInstance(context)
        val tag = reminderTag(club)
        val previous = scheduled[club]
        if (previous == null) manager.cancelAllWorkByTag(tag)
        else (previous.keys - upcoming.keys).forEach { manager.cancelUniqueWork("$tag/$it") }
        for ((checkpoint, time) in upcoming) {
            if (previous?.get(checkpoint) == time) continue
            val request = OneTimeWorkRequestBuilder<ClubReminderWorker>()
                .setInitialDelay(time - now, TimeUnit.MILLISECONDS)
                .addTag(tag)
                .build()
            manager.enqueueUniqueWork("$tag/$checkpoint", ExistingWorkPolicy.REPLACE, request)
        }
        scheduled[club] = upcoming
    }

    private fun cancelReminders(club: String) {
        scheduled.remove(club)
        WorkManager.getInstance(context).cancelAllWorkByTag(reminderTag(club))
    }

    private fun reminderTag(club: String) = "enve-book-club/${storage.profileId}/$club"

    override suspend fun shareProgress(club: String, read: String, enabled: Boolean, presence: Boolean) {
        val result: ClubSharing = call(readPath(club, read) + "/sharing", "PUT", buildJsonObject { put("enabled", enabled); put("presence", presence) })
        local.pending.remove(read)
        lastUpdates.remove(read)
        lastChapter.remove(read)
        local.copies[read]?.let { copy ->
            local.copies[read] = copy.copy(sharing = if (enabled) result else null)
            if (enabled) record(copy.bookKey, copy.lastProgress, false)
        }
        save()
    }

    override suspend fun posts(club: String, read: String, checkpoint: String?, before: String?): ClubPosts =
        call(readPath(club, read) + "/threads/${checkpoint ?: "general"}", before = before)
    override suspend fun post(club: String, read: String, checkpoint: String?, body: String, passage: String?, chapter: String?, parent: String?) {
        call<ID>(readPath(club, read) + "/threads/${checkpoint ?: "general"}", "POST",
            objectOf("body" to body, "passage" to passage, "passageChapter" to chapter, "parentID" to parent))
    }
    override suspend fun react(club: String, read: String, post: String, emoji: String, enabled: Boolean) =
        ok(readPath(club, read) + "/posts/$post/reaction", "PUT", buildJsonObject { put("emoji", emoji); put("enabled", enabled) })
    override suspend fun report(club: String, read: String, post: String, reason: String) =
        ok(readPath(club, read) + "/posts/$post/report", "POST", objectOf("reason" to reason))
    override suspend fun deletePost(club: String, read: String, post: String) = ok(readPath(club, read) + "/posts/$post", "DELETE")
    override suspend fun nextUp(club: String): ClubNextUp = call("clubs/$club/next")
    override suspend fun nominate(club: String, title: String, author: String?) {
        call<ID>("clubs/$club/nominations", "POST", objectOf("name" to title, "author" to author))
    }
    override suspend fun startPoll(club: String, title: String, choices: List<String>, closesAt: Long?) {
        call<ID>("clubs/$club/polls", "POST", buildJsonObject {
            put("name", title)
            closesAt?.let { put("closesAt", it) }
            putJsonArray("optionIDs") { choices.forEach { add(JsonPrimitive(it)) } }
        })
    }
    override suspend fun vote(club: String, poll: String, choice: String) = ok("clubs/$club/polls/$poll/vote", "PUT", objectOf("nominationID" to choice))
    override suspend fun closePoll(club: String, poll: String, winner: String?) = ok("clubs/$club/polls/$poll/close", "POST", objectOf("winnerID" to winner))

    override fun recordReading(book: Book, fraction: Double, chapter: String?, chapterOrder: List<String>) {
        if (!available || book.uniqueKey !in _copies.value.values) return
        scope.launch(Dispatchers.Main.immediate) {
            record(book.uniqueKey, fraction, true, chapter = chapter, chapterOrder = chapterOrder)
        }
    }

    private fun record(
        bookKey: String, fraction: Double, active: Boolean, durationMs: Long? = null,
        chapter: String? = null, chapterOrder: List<String> = emptyList(),
    ) {
        if (_account.value == null || !fraction.isFinite()) return
        val now = System.currentTimeMillis()
        var changed = false
        local.copies.values.filter { it.bookKey == bookKey }.forEach { copy ->
            val share = copy.sharing ?: return@forEach
            val epoch = share.epoch ?: return@forEach
            val bounded = fraction.coerceIn(0.0, 1.0)
            val previous = lastUpdates[copy.readID]
            val present = active && share.presence
            if (chapter == null && previous != null && now - previous.observedAt < 7_000 && previous.active == present) return@forEach
            val currentChapter = chapter?.let(::normalizeChapter)
            val previousChapter = if (currentChapter != null) lastChapter.put(copy.readID, currentChapter) else null
            if (previousChapter == currentChapter && previous?.fraction == bounded && previous.active == present && (!present || now - (lastWrites[copy.readID] ?: 0) < 30_000)) return@forEach
            val update = Progress(epoch, bounded, now, present)
            lastUpdates[copy.readID] = update
            var step = local.pending[copy.readID]?.checkpoint
            if (durationMs != null && previous != null && now - previous.observedAt < 120_000) {
                val distance = (bounded - previous.fraction) * durationMs
                if (distance > 0 && distance < (now - previous.observedAt) * 4 + 3000) {
                    val crossed = copy.checkpoints.lastOrNull { id ->
                        copy.ends[copy.checkpointNames[id]]?.let { previous.fraction < it && bounded >= it } == true
                    }
                    if (crossed != null && copy.checkpoints.indexOf(crossed) > copy.checkpoints.indexOf(step)) step = crossed
                }
            }
            if (currentChapter != null && previousChapter != null && currentChapter != previousChapter && bounded >= (previous?.fraction ?: 0.0)) {
                val order = chapterOrder.map(::normalizeChapter)
                val index = order.indexOf(previousChapter)
                if (index >= 0 && index == order.lastIndexOf(previousChapter) &&
                    order.getOrNull(index + 1) == currentChapter && order.indexOf(currentChapter) == order.lastIndexOf(currentChapter)) {
                    val crossed = copy.checkpoints.lastOrNull { copy.checkpointNames[it] == previousChapter }
                    if (crossed != null && copy.checkpoints.indexOf(crossed) > copy.checkpoints.indexOf(step)) step = crossed
                }
            }
            local.pending[copy.readID] = Pending(update, step)
            local.copies[copy.readID] = copy.copy(lastProgress = bounded)
            changed = true
        }
        if (changed) save()
    }

    private suspend fun flush() {
        if (_account.value == null) return
        for ((read, pending) in local.pending.toMap()) {
            val copy = local.copies[read] ?: continue
            if (System.currentTimeMillis() - (lastWrites[read] ?: 0) < 25_000) continue
            val path = readPath(copy.clubID, read)
            try {
                ok("$path/progress", "PUT", json.encodeToJsonElement(Progress.serializer(), pending.progress))
                if (copy.sharing?.epoch == local.copies[read]?.sharing?.epoch) pending.checkpoint?.let {
                    ok("$path/checkpoints/$it/complete", "PUT", objectOf("epoch" to pending.progress.epoch))
                }
                if (local.pending[read] == pending) local.pending.remove(read)
                lastWrites[read] = System.currentTimeMillis()
                save()
            } catch (error: CancellationException) {
                throw error
            } catch (error: ClubRequestException) {
                if (error.status in listOf(400, 403, 404, 409) && local.pending[read]?.progress?.epoch == pending.progress.epoch) {
                    local.pending.remove(read)
                    if (error.status != 400) local.copies[read] = copy.copy(sharing = null)
                    save()
                }
            } catch (_: IOException) {
                continue
            }
        }
    }

    private val stateKey: String get() = "club_state_$endpoint/${credentials?.account?.id}"
    private fun loadState(): LocalState = if (credentials == null) LocalState() else
        vault.get(stateKey)?.let { runCatching { json.decodeFromString<LocalState>(it) }.getOrNull() } ?: LocalState()
    private fun save() {
        if (credentials != null) vault.put(stateKey, json.encodeToString(local))
        refreshCopies()
    }
    private fun refreshCopies() { _copies.value = local.copies.mapValues { it.value.bookKey } }
    private fun readPath(club: String, read: String) = "clubs/$club/reads/$read"
    private fun objectOf(vararg values: Pair<String, String?>) = buildJsonObject { values.forEach { (key, value) -> if (value != null) put(key, value) } }

    private suspend fun ok(path: String, method: String, body: kotlinx.serialization.json.JsonElement? = null) {
        call<Acknowledgement>(path, method, body)
    }

    private suspend inline fun <reified T> call(path: String, method: String = "GET", body: kotlinx.serialization.json.JsonElement? = null,
                                               authenticated: Boolean = true, before: String? = null): T {
        val root = endpoint ?: throw IOException("Book Clubs is unavailable.")
        val session = if (authenticated) credentials?.takeIf { _account.value != null } ?: throw IOException("Sign in to Clubs.") else null
        val url = root.newBuilder().addPathSegment("v1").apply {
            path.split('/').forEach { addPathSegment(it) }
            before?.let { addQueryParameter("before", it) }
        }.build()
        val content = (body?.toString() ?: "{}").toRequestBody("application/json".toMediaType())
        val request = Request.Builder().url(url).method(method, if (method == "GET" || method == "DELETE") null else content)
            .apply { session?.let { header("Authorization", "Bearer ${it.token}") } }.build()
        val result = execute(request)
        if (result.first !in 200..299) {
            if (authenticated && result.first == 401 && session == credentials) _account.value = null
            val message = runCatching { json.decodeFromString<Failure>(result.second).error }.getOrNull()
            throw ClubRequestException(result.first, message ?: "Book Clubs is temporarily unavailable.")
        }
        if (authenticated && session != credentials) throw CancellationException("Clubs profile changed")
        return json.decodeFromString(result.second)
    }

    private suspend fun execute(request: Request): Pair<Int, String> = suspendCancellableCoroutine { continuation ->
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) { continuation.resumeWithException(e) }
            override fun onResponse(call: Call, response: Response) {
                try { response.use { continuation.resume(it.code to it.body?.string().orEmpty()) } }
                catch (error: IOException) { continuation.resumeWithException(error) }
            }
        })
    }

    @Serializable private data class Credentials(val account: ClubAccount, val token: String, val recoveryKey: String)
    @Serializable private data class Recovery(val recoveryKey: String)
    @Serializable private data class ID(val id: String)
    @Serializable private data class Failure(val error: String)
    @Serializable private data class Acknowledgement(val ok: Boolean)
    @Serializable private data class Copy(val clubID: String, val readID: String, val bookKey: String, val lastProgress: Double,
                                        val ends: Map<String, Double>, val checkpoints: List<String>,
                                        val checkpointNames: Map<String, String> = emptyMap(), val sharing: ClubSharing? = null)
    @Serializable private data class Pending(val progress: Progress, val checkpoint: String? = null)
    @Serializable private data class Progress(val epoch: String, val fraction: Double, val observedAt: Long, val active: Boolean)
    @Serializable private data class LocalState(
        val copies: MutableMap<String, Copy> = mutableMapOf(),
        val pending: MutableMap<String, Pending> = mutableMapOf(),
        val reminderClubs: MutableSet<String> = mutableSetOf(),
    )
    private class ClubRequestException(val status: Int, message: String) : IOException(message)

    private fun normalizeChapter(value: String): String = Normalizer.normalize(value, Normalizer.Form.NFD)
        .replace(Regex("\\p{M}+"), "").lowercase(Locale.ROOT).split(Regex("[^\\p{L}\\p{N}]+")).filter(String::isNotEmpty).joinToString(" ")
}
