// AGENT-LOCKED
package com.enve.bookorbit.auth

import com.enve.bookorbit.api.BookOrbitApi
import com.enve.bookorbit.dto.BookOrbitLoginRequest
import com.enve.core.data.auth.PasswordLogin
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class BookOrbitPasswordLogin @Inject constructor(
    private val api: BookOrbitApi,
    private val prefs: PreferencesManager,
    private val vault: CredentialVault,
) : PasswordLogin {
    override val source: BookSource = BookSource.BOOKORBIT

    override suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> = runCatching {
        val response = api.login(BookOrbitLoginRequest(username = username, password = password))
        if (!response.isSuccessful) {
            error("BookOrbit login failed: HTTP ${response.code()} ${response.message()}".trim())
        }
        val accessToken = response.body()?.accessToken?.takeIf { it.isNotBlank() }
            ?: error("BookOrbit login returned no access token")
        val refreshToken = BookOrbitAuthCookies.refreshToken(response.headers())
        prefs.saveAuth(accessToken, refreshToken)
        vault.put(CredentialVault.KEY_PASSWORD, password)
    }
}
