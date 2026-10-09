package com.enve.app.data.local

import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.local.ProfilePreferences
import com.enve.core.data.local.ProfileStorageLocations
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID
import java.io.File

@RunWith(AndroidJUnit4::class)
class CredentialVaultProfileTest {
    private val context = VaultTestContext(ApplicationProvider.getApplicationContext())

    @After
    fun cleanUp() = context.clear()

    @Test
    fun ownerKeepsLegacyCredentialsAndChildStartsEmpty() {
        val legacy = CredentialVault(context)
        val key = CredentialVault.accessTokenKey("same-connection")
        legacy.put(key, "owner-test-token")
        legacy.put(CredentialVault.KEY_PASSWORD, "owner-test-password")

        val owner = CredentialVault.forProfile(context, DEFAULT_ADULT_PROFILE_ID)
        val child = CredentialVault.forProfile(context, "child")
        assertEquals("owner-test-token", owner.get(key))
        assertEquals("owner-test-password", owner.get(CredentialVault.KEY_PASSWORD))
        assertNull(child.get(key))
        assertNull(child.get(CredentialVault.KEY_PASSWORD))
        child.put(key, "child-test-token")

        assertEquals("owner-test-token", legacy.get(key))
        assertEquals("child-test-token", CredentialVault.forProfile(context, "child").get(key))
    }

    @Test
    fun clearingOneProfilePreservesOthersAndTheirGlobalSecrets() {
        val owner = CredentialVault(context)
        val child = CredentialVault.forProfile(context, "child")
        val other = CredentialVault.forProfile(context, "other")
        val keys = listOf(
            CredentialVault.KEY_ACCESS_TOKEN,
            CredentialVault.KEY_REFRESH_TOKEN,
            CredentialVault.passwordKey("same-connection"),
            CredentialVault.serviceClientSecretKey("same-connection"),
        )
        for (key in keys) {
            owner.put(key, "owner-test-value")
            child.put(key, "child-test-value")
            other.put(key, "other-test-value")
        }

        child.clearAll()

        for (key in keys) {
            assertNull(child.get(key))
            assertEquals("owner-test-value", owner.get(key))
            assertEquals("other-test-value", other.get(key))
        }
    }

    @Test
    fun logoutOnlyClearsTheCapturedProfilesLogin() = runBlocking {
        val root = File(context.cacheDir, "profile-login-test-${UUID.randomUUID()}")
        val job = SupervisorJob()
        try {
            val scope = CoroutineScope(job + Dispatchers.IO)
            fun preferences(id: String): PreferencesManager {
                val locations = ProfileStorageLocations.forProfile(
                    id, File(root, "files"), File(root, "cache"), File(root, "databases"),
                )
                val resources = ProfilePreferences.open(context, locations, scope)
                return PreferencesManager(resources.enve, CredentialVault.forProfile(context, id), scope)
            }
            val first = preferences("first")
            val second = preferences("second")
            first.saveServerInfo("https://first.invalid", "First")
            first.saveAuth("first-test-token", "first-test-refresh")
            assertNull(second.getAccessTokenSync())
            assertNull(second.serverUrl.first())
            second.saveServerInfo("https://second.invalid", "Second")
            second.saveAuth("second-test-token", "second-test-refresh")

            second.clearAuth()

            assertEquals("first-test-token", first.getAccessTokenSync())
            assertEquals("first-test-refresh", first.getRefreshTokenSync())
            assertEquals("https://first.invalid", first.serverUrl.first())
            assertEquals("First", first.username.first())
            assertNull(second.getAccessTokenSync())
            assertNull(second.getRefreshTokenSync())
            assertNull(second.serverUrl.first())
        } finally {
            job.cancelAndJoin()
            root.deleteRecursively()
        }
    }

    private class VaultTestContext(base: Context) : ContextWrapper(base) {
        private val prefix = "vault-test-${UUID.randomUUID()}-"
        private val names = mutableSetOf<String>()

        override fun getApplicationContext(): Context = this

        override fun getSharedPreferences(name: String, mode: Int) =
            baseContext.getSharedPreferences(prefix + name, mode).also { names += prefix + name }

        fun clear() {
            names.forEach(baseContext::deleteSharedPreferences)
        }
    }
}
