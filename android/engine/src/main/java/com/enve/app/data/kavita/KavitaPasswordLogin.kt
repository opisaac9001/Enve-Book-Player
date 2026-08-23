// AGENT-LOCKED
package com.enve.app.data.kavita

import com.enve.core.data.auth.PasswordLogin
import com.enve.app.data.remote.GrimmoryApi
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import com.enve.core.data.remote.dto.LoginRequest
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonPrimitive
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class KavitaPasswordLogin @Inject constructor(
    private val api: GrimmoryApi,
    private val prefs: PreferencesManager,
) : PasswordLogin {

    override val source: BookSource = BookSource.KAVITA

    override suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> = runCatching {
        val response = api.kavitaLogin(LoginRequest(username = username, password = password))
        if (!response.isSuccessful) {
            if (response.code() == 401) error("Invalid username or password")
            error("Kavita login failed: HTTP ${response.code()}")
        }
        val token = response.body()?.get("token")?.jsonPrimitive?.contentOrNull
            ?.takeIf { it.isNotBlank() }
            ?: error("Kavita did not return an access token")
        prefs.saveAuth(token, null)
    }
}
