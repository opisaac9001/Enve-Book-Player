package com.enve.core.data.history

import com.enve.core.data.model.HistorySession
import kotlinx.coroutines.flow.StateFlow

interface HistorySessionRepository {
    val sessions: StateFlow<List<HistorySession>>

    suspend fun append(session: HistorySession): Boolean

    suspend fun replaceBookOrbitSessions(
        connectionId: String,
        bookKey: String,
        sessions: List<HistorySession>,
    ): Int
}
