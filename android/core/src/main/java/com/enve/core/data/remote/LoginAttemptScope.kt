package com.enve.core.data.remote

import com.enve.core.data.model.BookSource
import kotlinx.coroutines.asContextElement

class LoginAttempt(
    val serverUrl: String,
    val source: BookSource,
    val headers: Map<String, String>,
    val username: String = "",
) {
    @Volatile var refreshToken: String? = null
        internal set
    @Volatile var accessToken: String? = null
        internal set
}

object LoginAttemptScope {
    private val current = ThreadLocal<LoginAttempt?>()

    fun get(): LoginAttempt? = current.get()

    fun asContextElement(attempt: LoginAttempt) = current.asContextElement(attempt)

    fun <T> withAttempt(attempt: LoginAttempt?, block: () -> T): T {
        val previous = current.get()
        current.set(attempt)
        try {
            return block()
        } finally {
            current.set(previous)
        }
    }
}
