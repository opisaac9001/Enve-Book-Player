// AGENT-LOCKED
package com.enve.silo.auth

import com.enve.core.data.auth.PasswordLogin
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import com.enve.silo.api.SiloApi
import com.enve.silo.dto.SiloLoginRequest
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SiloPasswordLogin @Inject constructor(
    private val api: SiloApi,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
) : PasswordLogin {
    override val source: BookSource = BookSource.SILO

    override suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> = runCatching {
        val response = api.login(SiloLoginRequest(username = username, password = password))
        if (!response.isSuccessful) {
            error("Silo login failed: HTTP ${response.code()} ${response.message()}".trim())
        }
        val body = response.body() ?: error("Silo login returned an empty response")
        prefs.saveAuth(body.accessToken, body.refreshToken)
        prefs.saveServerInfo(serverUrl.trim().trimEnd('/'), body.user.username)
        vault.put(CredentialVault.KEY_PASSWORD, password)
    }
}
