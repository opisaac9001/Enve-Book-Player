// AGENT-LOCKED
package com.enve.app.data.grimmory.auth

import com.enve.core.data.auth.PasswordLogin
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import com.enve.app.data.remote.GrimmoryApi
import com.enve.core.data.remote.dto.LoginRequest
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class GrimmoryPasswordLogin @Inject constructor(
    private val api: GrimmoryApi,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
) : PasswordLogin {

    override val source: BookSource = BookSource.GRIMMORY

    override suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> = runCatching {
        val normalizedUrl = serverUrl.trimEnd('/')
        val response = api.loginAt("$normalizedUrl/api/v1/auth/login", LoginRequest(username, password))
        if (!response.isSuccessful) {
            error("Login failed: ${response.code()} ${response.message()}")
        }
        val auth = response.body() ?: error("Missing auth response")
        prefs.saveAuth(auth.accessToken, auth.refreshToken)
        vault.put(CredentialVault.kosyncUsernameKey(normalizedUrl), username)
        vault.put(CredentialVault.kosyncPasswordKey(normalizedUrl), password)
        vault.put(CredentialVault.KEY_PASSWORD, password)
    }
}
