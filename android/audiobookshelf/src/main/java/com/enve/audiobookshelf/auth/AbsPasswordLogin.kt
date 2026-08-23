// AGENT-LOCKED
package com.enve.audiobookshelf.auth

import com.enve.core.data.auth.PasswordLogin
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import com.enve.audiobookshelf.api.AudiobookshelfApi
import com.enve.core.data.remote.dto.AbsLoginRequest
import com.enve.core.data.remote.dto.AbsLoginResponse
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AbsPasswordLogin @Inject constructor(
    private val api: AudiobookshelfApi,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
) : PasswordLogin {

    override val source: BookSource = BookSource.AUDIOBOOKSHELF

    override suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> = runCatching {
        val normalizedUrl = serverUrl.trimEnd('/')
        val response = api.loginAt("$normalizedUrl/login", AbsLoginRequest(username, password))
        if (!response.isSuccessful) {
            error("Login failed: ${response.code()} ${response.message()}")
        }
        val auth = response.body() ?: error("Missing auth response")
        val accessToken = auth.user?.accessToken ?: auth.user?.token ?: auth.accessToken
        val refreshToken = auth.user?.refreshToken ?: auth.refreshToken
        if (accessToken.isNullOrBlank()) {
            error("Login succeeded but no token was returned")
        }
        prefs.saveAuth(accessToken, refreshToken)
        vault.put(CredentialVault.KEY_PASSWORD, password)
    }
}
