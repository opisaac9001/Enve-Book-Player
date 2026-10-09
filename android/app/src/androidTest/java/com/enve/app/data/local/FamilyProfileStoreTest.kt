package com.enve.app.data.local

import android.content.Context
import android.content.ContextWrapper
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.enve.core.data.local.AdultPinResult
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.FamilyProfileRole
import com.enve.core.data.local.FamilyProfileStore
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class FamilyProfileStoreTest {
    private val contexts = mutableListOf<ProfileTestContext>()

    @After
    fun cleanUp() {
        contexts.forEach(ProfileTestContext::clear)
    }

    @Test
    fun restoresAdultAndChildProfilesWithoutChangingTheirIdentity() {
        val context = context()
        val store = FamilyProfileStore(context)
        val adult = store.addAdult("  Sam  ")
        assertThrows(IllegalArgumentException::class.java) { store.addChild("Alex") }
        assertEquals(AdultPinResult.Accepted, store.setAdultPin("291746"))
        val child = store.addChild("Alex")
        store.rename(adult.id, "Samuel")

        val restored = FamilyProfileStore(context).profiles.value

        assertEquals(DEFAULT_ADULT_PROFILE_ID, restored.first().id)
        assertEquals(FamilyProfileRole.ADULT, restored.first().role)
        assertEquals(adult.copy(name = "Samuel"), restored.first { it.id == adult.id })
        assertEquals(child, restored.first { it.id == child.id })
        assertEquals(3, restored.size)
    }

    @Test
    fun invalidNamesDoNotChangePersistedProfiles() {
        val context = context()
        val store = FamilyProfileStore(context)
        val original = store.profiles.value

        assertThrows(IllegalArgumentException::class.java) { store.addAdult("   ") }
        assertThrows(IllegalArgumentException::class.java) { store.addAdult("a".repeat(41)) }
        assertThrows(IllegalArgumentException::class.java) { store.rename(DEFAULT_ADULT_PROFILE_ID, "") }

        assertEquals(original, FamilyProfileStore(context).profiles.value)
    }

    @Test
    fun malformedCatalogDoesNotFallBackToAnAdultProfile() {
        val context = context()
        val preferences = EncryptedSharedPreferences.create(
            context,
            "family_profiles.secure",
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
        val catalogs = listOf(
            """[{"id":"child","name":"Alex","role":"CHILD"}]""",
            """[{"id":"adult-default","name":"Adult","role":"ADULT"},{"id":"../adult-default","name":"Alex","role":"CHILD"}]""",
            """[{"id":"adult-default","name":"Adult","role":"ADULT"},{"id":"adult-default","name":"Other","role":"ADULT"}]""",
        )
        for (catalog in catalogs) {
            preferences.edit().putString("profiles", catalog).commit()
            assertThrows(IllegalStateException::class.java) { FamilyProfileStore(context) }
        }
    }

    @Test
    fun changingPinRequiresTheExistingPin() {
        val context = context()
        val store = FamilyProfileStore(context)
        store.setAdultPin("291746")

        assertEquals(AdultPinResult.Rejected, store.setAdultPin("638152", currentPin = "000000"))
        assertEquals(AdultPinResult.Accepted, FamilyProfileStore(context).verifyAdultPin("291746"))
        assertEquals(AdultPinResult.Accepted, store.setAdultPin("638152", currentPin = "291746"))
        val restored = FamilyProfileStore(context)
        assertEquals(AdultPinResult.Rejected, restored.verifyAdultPin("291746"))
        assertEquals(AdultPinResult.Accepted, restored.verifyAdultPin("638152"))
    }

    @Test
    fun lockoutSurvivesStoreRecreationAndExpires() {
        val context = context()
        val store = FamilyProfileStore(context)
        store.setAdultPin("291746")
        val now = 1_700_000_000_000L
        repeat(4) {
            assertEquals(AdultPinResult.Rejected, store.verifyAdultPin("000000", now))
        }
        assertEquals(AdultPinResult.Locked(now + 60_000), store.verifyAdultPin("000000", now))
        val restored = FamilyProfileStore(context)
        assertEquals(AdultPinResult.Locked(now + 60_000), restored.verifyAdultPin("291746", now + 59_999))
        assertEquals(AdultPinResult.Accepted, restored.verifyAdultPin("291746", now + 60_000))
        assertTrue(restored.hasAdultPin)
    }

    private fun context(): ProfileTestContext =
        ProfileTestContext(ApplicationProvider.getApplicationContext()).also(contexts::add)

    private class ProfileTestContext(base: Context) : ContextWrapper(base) {
        private val prefix = "profile-test-${UUID.randomUUID()}-"
        private val names = mutableSetOf<String>()

        override fun getApplicationContext(): Context = this

        override fun getSharedPreferences(name: String, mode: Int) =
            baseContext.getSharedPreferences(prefix + name, mode).also { names += prefix + name }

        fun clear() {
            names.forEach(baseContext::deleteSharedPreferences)
        }
    }
}
