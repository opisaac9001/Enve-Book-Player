package com.enve.app.data.history

import android.content.Context
import android.util.AtomicFile
import com.enve.core.data.history.HistorySessionRepository
import com.enve.core.data.model.HistorySession
import com.enve.core.data.model.HistorySessionOrigin
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.io.File
import java.io.FileOutputStream
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class HistorySessionStore @Inject constructor(
    @ApplicationContext context: Context,
) : HistorySessionRepository {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }
    private val file = AtomicFile(
        File(context.filesDir, "history/history_sessions.json").also {
            it.parentFile?.mkdirs()
        },
    )
    private val serializer = ListSerializer(HistorySession.serializer())
    private val mutex = Mutex()
    private val mutableSessions = MutableStateFlow(load())

    override val sessions: StateFlow<List<HistorySession>> = mutableSessions.asStateFlow()

    override suspend fun append(session: HistorySession): Boolean = mutex.withLock {
        val updated = trim(listOf(session) + mutableSessions.value.filterNot { it.id == session.id })
        val persisted = withContext(Dispatchers.IO) { persist(updated) }
        if (persisted) mutableSessions.value = updated
        persisted
    }

    override suspend fun replaceBookOrbitSessions(
        connectionId: String,
        bookKey: String,
        sessions: List<HistorySession>,
    ): Int = mutex.withLock {
        val current = mutableSessions.value
        fun HistorySession.belongsToBook(): Boolean =
            this.connectionId == connectionId && this.bookKey == bookKey
        val previousRemoteIds = current.asSequence()
            .filter { it.belongsToBook() && it.origin == HistorySessionOrigin.BOOKORBIT }
            .map(HistorySession::id)
            .toSet()
        val local = current.filter { it.belongsToBook() && it.origin == HistorySessionOrigin.LOCAL }
        val imported = sessions.filter { remote ->
            local.none { existing ->
                kotlin.math.abs(existing.startTimeMs - remote.startTimeMs) <= SESSION_MATCH_TOLERANCE_MS &&
                    kotlin.math.abs(existing.endTimeMs - remote.endTimeMs) <= SESSION_MATCH_TOLERANCE_MS &&
                    kotlin.math.abs(existing.activeDurationSeconds - remote.activeDurationSeconds) <=
                    SESSION_DURATION_TOLERANCE_SECONDS
            }
        }
        val importedIds = imported.map(HistorySession::id).toSet()
        val updated = trim(
            imported + current.filterNot { it.belongsToBook() && it.origin == HistorySessionOrigin.BOOKORBIT },
        )
        val persisted = withContext(Dispatchers.IO) { persist(updated) }
        if (persisted) mutableSessions.value = updated
        if (persisted) previousRemoteIds.union(importedIds).minus(previousRemoteIds.intersect(importedIds)).size else 0
    }

    private fun trim(sessions: List<HistorySession>): List<HistorySession> {
        val ordered = sessions.sortedByDescending(HistorySession::endTimeMs)
        if (ordered.size <= MAX_SESSIONS) return ordered
        val local = ordered.filter { it.origin == HistorySessionOrigin.LOCAL }
        val retainedRemoteIds = ordered.asSequence()
            .filter { it.origin != HistorySessionOrigin.LOCAL }
            .take((MAX_SESSIONS - local.size).coerceAtLeast(0))
            .map(HistorySession::id)
            .toSet()
        return ordered
            .filter { it.origin == HistorySessionOrigin.LOCAL || it.id in retainedRemoteIds }
            .take(MAX_SESSIONS)
    }

    private fun load(): List<HistorySession> {
        if (!file.baseFile.exists()) return emptyList()
        return try {
            file.openRead().bufferedReader().use { reader ->
                json.decodeFromString(serializer, reader.readText())
            }
                .sortedByDescending(HistorySession::endTimeMs)
                .take(MAX_SESSIONS)
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun persist(sessions: List<HistorySession>): Boolean {
        var output: FileOutputStream? = null
        return try {
            val encoded = json.encodeToString(serializer, sessions).toByteArray()
            val stream = file.startWrite()
            output = stream
            stream.write(encoded)
            file.finishWrite(stream)
            true
        } catch (_: Exception) {
            output?.let(file::failWrite)
            false
        }
    }

    private companion object {
        const val MAX_SESSIONS = 1_000
        const val SESSION_MATCH_TOLERANCE_MS = 2_000L
        const val SESSION_DURATION_TOLERANCE_SECONDS = 2L
    }
}
