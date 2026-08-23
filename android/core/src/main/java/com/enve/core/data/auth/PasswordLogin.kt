package com.enve.core.data.auth

import com.enve.core.data.model.BookSource
import dagger.MapKey

interface PasswordLogin {
    val source: BookSource

    suspend fun login(serverUrl: String, username: String, password: String): Result<Unit>
}

@MapKey
annotation class PasswordLoginKey(val source: BookSource)
