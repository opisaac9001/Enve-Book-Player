// AGENT-LOCKED
package com.enve.core.auth

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class CredentialVault @Inject constructor(
    @ApplicationContext context: Context,
) {
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()

    private val prefs = EncryptedSharedPreferences.create(
        context,
        FILE_NAME,
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    fun put(key: String, value: String?) {
        val editor = prefs.edit()
        if (value == null) {
            editor.remove(key)
        } else {
            editor.putString(key, value)
        }
        editor.commit()
    }

    fun get(key: String): String? = prefs.getString(key, null)

    fun remove(key: String) {
        prefs.edit().remove(key).apply()
    }

    fun clearAll() {
        prefs.edit().clear().apply()
    }

    companion object {
        private const val FILE_NAME = "enve_credentials"

        const val KEY_ACCESS_TOKEN = "grimmory_access_token"
        const val KEY_REFRESH_TOKEN = "grimmory_refresh_token"
        const val KEY_PASSWORD = "enve_login_password"

        fun accessTokenKey(connectionId: String) = "access_token_$connectionId"
        fun refreshTokenKey(connectionId: String) = "refresh_token_$connectionId"
        fun passwordKey(connectionId: String) = "password_$connectionId"
        fun usernameKey(connectionId: String) = "username_$connectionId"

        fun kosyncPasswordKey(serverUrl: String) = "kosync_password::$serverUrl"
        fun kosyncUsernameKey(serverUrl: String) = "kosync_username::$serverUrl"
        fun kosyncUsernameKeyForConnection(connectionId: String) = "kosync_username_$connectionId"
        fun kosyncPasswordKeyForConnection(connectionId: String) = "kosync_password_$connectionId"

        const val KOSYNC_HUB_PASSWORD_HASH = "kosync_hub_password_hash"
        const val KOSYNC_HUB_LINKS_JSON = "kosync_hub_links_json"
        const val HARDCOVER_API_KEY = "hardcover_api_key"

        fun mtlsCertKey(connectionId: String) = "mtls_cert_$connectionId"
        fun mtlsCertPasswordKey(connectionId: String) = "mtls_cert_pass_$connectionId"
        fun serviceClientIdKey(connectionId: String) = "svc_client_id_$connectionId"
        fun serviceClientSecretKey(connectionId: String) = "svc_client_secret_$connectionId"
    }
}
