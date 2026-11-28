package com.enve.engine.clubs

import com.enve.core.data.model.Book
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.Serializable

@Serializable
data class ClubAccount(val id: String, val name: String)

@Serializable
data class ClubSummary(val id: String, val name: String, val currentTitle: String? = null)

@Serializable
data class ClubRead(val id: String, val title: String, val author: String? = null, val closedAt: Long? = null)

@Serializable
data class ClubActivity(val id: String, val memberName: String? = null, val kind: String, val label: String, val createdAt: Long)

@Serializable
data class ClubDetails(
    val id: String, val name: String, val ownerID: String, val members: List<ClubAccount>,
    val reads: List<ClubRead>, val activity: List<ClubActivity>, val blockedIDs: List<String>,
) {
    val current: ClubRead? get() = reads.firstOrNull { it.closedAt == null }
}

@Serializable
data class ClubCheckpoint(
    val id: String, val label: String, val chapterKey: String? = null, val dueAt: Long? = null,
    val trackPosition: Double? = null, val sortOrder: Int,
)

@Serializable
data class ClubCheckpointDraft(
    val label: String, val chapterKey: String? = null, val dueAt: Long? = null, val trackPosition: Double? = null,
)

@Serializable
data class ClubReadDraft(
    val title: String, val author: String? = null, val series: String? = null,
    val checkpoints: List<ClubCheckpointDraft>, val pollID: String? = null,
)

@Serializable
data class ClubPosition(val accountID: String, val fraction: Double, val activeUntil: Long? = null)

@Serializable
data class ClubCompletion(val checkpointID: String, val accountID: String)

@Serializable
data class ClubSharing(val epoch: String? = null, val presence: Boolean)

@Serializable
data class ClubReadDetails(
    val read: ClubRead, val checkpoints: List<ClubCheckpoint>, val progress: List<ClubPosition>,
    val completions: List<ClubCompletion>, val sharing: ClubSharing? = null,
)

@Serializable
data class ClubInvite(val code: String, val expiresAt: Long)

@Serializable
data class ClubReaction(val accountID: String, val emoji: String)

@Serializable
data class ClubPost(
    val id: String, val authorID: String, val authorName: String, val parentID: String? = null,
    val body: String, val passage: String? = null, val passageChapter: String? = null,
    val createdAt: Long, val reactions: List<ClubReaction>,
)

@Serializable
data class ClubPosts(val posts: List<ClubPost>, val before: String? = null, val archived: Boolean)

@Serializable
data class ClubNomination(val id: String, val name: String, val author: String? = null, val memberName: String? = null)

@Serializable
data class ClubVote(val nominationID: String, val accountID: String, val memberName: String)

@Serializable
data class ClubPoll(
    val id: String, val name: String, val optionIDs: List<String>, val votes: List<ClubVote>,
    val closesAt: Long? = null, val closedAt: Long? = null, val winnerID: String? = null, val startedReadID: String? = null,
)

@Serializable
data class ClubNextUp(val nominations: List<ClubNomination>, val polls: List<ClubPoll>)

interface ClubsFacade {
    val available: Boolean
    val account: StateFlow<ClubAccount?>
    val copies: StateFlow<Map<String, String>>
    val reminders: StateFlow<Set<String>>
    fun inviteLink(code: String): String
    fun recoveryKey(): String?
    suspend fun createProfile(name: String)
    suspend fun restoreProfile(key: String)
    suspend fun replaceRecoveryKey()
    suspend fun endSession(delete: Boolean)
    suspend fun clubs(): List<ClubSummary>
    suspend fun createClub(name: String, read: ClubReadDraft?): String
    suspend fun join(code: String): String
    suspend fun club(id: String): ClubDetails
    suspend fun invite(club: String): ClubInvite
    suspend fun revokeInvite(club: String)
    suspend fun leave(club: String, delete: Boolean)
    suspend fun transfer(club: String, member: String)
    suspend fun remove(club: String, member: String)
    suspend fun block(member: String, enabled: Boolean)
    suspend fun read(club: String, read: String): ClubReadDetails
    suspend fun startRead(club: String, draft: ClubReadDraft): String
    suspend fun setCheckpoint(club: String, read: String, id: String?, checkpoint: ClubCheckpointDraft)
    suspend fun complete(club: String, read: String, checkpoint: String)
    suspend fun linkCopy(club: String, read: ClubReadDetails, book: Book?)
    fun setReminders(club: String, read: ClubReadDetails, enabled: Boolean)
    suspend fun shareProgress(club: String, read: String, enabled: Boolean, presence: Boolean)
    suspend fun posts(club: String, read: String, checkpoint: String?, before: String? = null): ClubPosts
    suspend fun post(club: String, read: String, checkpoint: String?, body: String, passage: String?, chapter: String?, parent: String?)
    suspend fun react(club: String, read: String, post: String, emoji: String, enabled: Boolean)
    suspend fun report(club: String, read: String, post: String, reason: String)
    suspend fun deletePost(club: String, read: String, post: String)
    suspend fun nextUp(club: String): ClubNextUp
    suspend fun nominate(club: String, title: String, author: String?)
    suspend fun startPoll(club: String, title: String, choices: List<String>, closesAt: Long?)
    suspend fun vote(club: String, poll: String, choice: String)
    suspend fun closePoll(club: String, poll: String, winner: String?)
    fun recordReading(book: Book, fraction: Double, chapter: String?, chapterOrder: List<String>)
}
