package com.enve.app.data.history

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.HistorySession
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AbsHistoryLinkTest {
    private val link = AbsHistoryLink(
        sourceBookKey = "source:book", sourceConnectionId = "source", sourceUsername = "reader", sourceAccountId = "stable-user",
        sourceServerUrl = "https://example.invalid", targetBookKey = "target:item",
        targetConnectionId = "target", targetAccountId = "account", targetServerUrl = "https://abs.invalid",
        confirmedAtMs = 50_000L,
    )
    private val session = HistorySession(
        id = "session", bookId = "book", bookKey = "source:book", connectionId = "source",
        source = BookSource.GRIMMORY, mediaType = AppMediaType.AUDIOBOOK,
        startTimeMs = 40_000L, endTimeMs = 60_000L, activeDurationSeconds = 10L,
    )

    @Test
    fun pastRequiresSeparateOptIn() {
        assertFalse(link.accepts(session))
        assertTrue(link.copy(includePast = true).accepts(session))
        assertTrue(link.accepts(session.copy(startTimeMs = 50_000L)))
    }

    @Test
    fun sourceConnectionAndBookMustMatch() {
        assertFalse(link.copy(includePast = true).accepts(session.copy(connectionId = "other")))
        assertFalse(link.copy(includePast = true).accepts(session.copy(bookKey = "source:other")))
    }
}
