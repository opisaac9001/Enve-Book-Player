package com.enve.app.data.opds

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

data class OpdsAuthSession(
    val flow: OpdsAuthenticationFlow,
    val username: String? = null,
    val password: String? = null,
    val accessToken: String? = null,
    val refreshToken: String? = null,
    val tokenUrl: String? = null,
    val refreshUrl: String? = null,
    val expiresAtMs: Long? = null,
) {
    val hasBearer: Boolean get() = !accessToken.isNullOrBlank()

    val hasBasic: Boolean get() = flow == OpdsAuthenticationFlow.BASIC && !username.isNullOrBlank()
}

@Singleton
class OpdsAuthStore @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val cached = ConcurrentHashMap<String, Cached>()

    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        FILE_NAME,
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    fun session(connectionId: String): OpdsAuthSession? {
        cached[connectionId]?.let { return it.value }
        val session = read(connectionId)
        cached[connectionId] = Cached(session)
        return session
    }

    private fun read(connectionId: String): OpdsAuthSession? {
        val flow = prefs.getString(key(connectionId, FLOW), null)
            ?.let { name -> OpdsAuthenticationFlow.entries.firstOrNull { it.name == name } }
            ?: return null
        return OpdsAuthSession(
            flow = flow,
            username = prefs.getString(key(connectionId, USERNAME), null),
            password = prefs.getString(key(connectionId, PASSWORD), null),
            accessToken = prefs.getString(key(connectionId, ACCESS_TOKEN), null),
            refreshToken = prefs.getString(key(connectionId, REFRESH_TOKEN), null),
            tokenUrl = prefs.getString(key(connectionId, TOKEN_URL), null),
            refreshUrl = prefs.getString(key(connectionId, REFRESH_URL), null),
            expiresAtMs = prefs.getLong(key(connectionId, EXPIRES_AT), 0L).takeIf { it > 0L },
        )
    }

    fun save(connectionId: String, session: OpdsAuthSession) {
        cached[connectionId] = Cached(session)
        prefs.edit()
            .putString(key(connectionId, FLOW), session.flow.name)
            .putString(key(connectionId, USERNAME), session.username)
            .putString(key(connectionId, PASSWORD), session.password)
            .putString(key(connectionId, ACCESS_TOKEN), session.accessToken)
            .putString(key(connectionId, REFRESH_TOKEN), session.refreshToken)
            .putString(key(connectionId, TOKEN_URL), session.tokenUrl)
            .putString(key(connectionId, REFRESH_URL), session.refreshUrl)
            .putLong(key(connectionId, EXPIRES_AT), session.expiresAtMs ?: 0L)
            .apply()
    }

    fun clear(connectionId: String) {
        cached.remove(connectionId)
        prefs.edit()
            .remove(key(connectionId, FLOW))
            .remove(key(connectionId, USERNAME))
            .remove(key(connectionId, PASSWORD))
            .remove(key(connectionId, ACCESS_TOKEN))
            .remove(key(connectionId, REFRESH_TOKEN))
            .remove(key(connectionId, TOKEN_URL))
            .remove(key(connectionId, REFRESH_URL))
            .remove(key(connectionId, EXPIRES_AT))
            .apply()
    }

    private fun key(connectionId: String, field: String): String = "$connectionId::$field"

    private class Cached(val value: OpdsAuthSession?)

    private companion object {
        const val FILE_NAME = "enve_opds_auth"
        const val FLOW = "flow"
        const val USERNAME = "username"
        const val PASSWORD = "password"
        const val ACCESS_TOKEN = "access_token"
        const val REFRESH_TOKEN = "refresh_token"
        const val TOKEN_URL = "token_url"
        const val REFRESH_URL = "refresh_url"
        const val EXPIRES_AT = "expires_at"
    }
}
