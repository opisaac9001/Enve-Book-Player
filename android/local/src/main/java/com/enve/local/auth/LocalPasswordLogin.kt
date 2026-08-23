// AGENT-LOCKED
package com.enve.local.auth

import com.enve.core.data.auth.PasswordLogin
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class LocalPasswordLogin @Inject constructor(
    private val prefs: PreferencesManager,
) : PasswordLogin {
    override val source: BookSource = BookSource.LOCAL

    override suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> = runCatching {
        prefs.saveAuth("local-session", null)
    }
}
