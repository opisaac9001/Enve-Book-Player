// AGENT-LOCKED
package com.enve.app.data.opds

import com.enve.app.data.remote.GrimmoryApi
import com.enve.core.data.auth.PasswordLogin
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.BookSource
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OpdsPasswordLogin @Inject constructor(
    private val prefs: PreferencesManager,
    private val api: GrimmoryApi,
) : PasswordLogin {
    override val source: BookSource = BookSource.OPDS
    override suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> = runCatching {
        prefs.saveAuth(password, null)
        val response = api.fetchRawUrl(serverUrl)
        val body = response.body()?.string().orEmpty()
        if (!response.isSuccessful) {
            if (response.code() == 401) error("Invalid OPDS username or password")
            error("OPDS HTTP ${response.code()}")
        }
        if (body.isBlank()) error("OPDS empty response")
    }
}

@Singleton
class WebDavPasswordLogin @Inject constructor(
    private val prefs: PreferencesManager,
) : PasswordLogin {
    override val source: BookSource = BookSource.WEBDAV
    override suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> = runCatching {
        prefs.saveAuth(password, null)
    }
}

@Singleton
class SmbPasswordLogin @Inject constructor(
    private val prefs: PreferencesManager,
) : PasswordLogin {
    override val source: BookSource = BookSource.SMB
    override suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> = runCatching {
        prefs.saveAuth(password, null)
    }
}

@Singleton
class LocalPasswordLogin @Inject constructor(
    private val prefs: PreferencesManager,
) : PasswordLogin {
    override val source: BookSource = BookSource.LOCAL
    override suspend fun login(serverUrl: String, username: String, password: String): Result<Unit> = runCatching {
        prefs.saveAuth("local-session", null)
    }
}
