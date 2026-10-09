package com.enve.core.data.local

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.UUID
import javax.inject.Inject
import javax.inject.Singleton

sealed interface AdultPinResult {
    data object Accepted : AdultPinResult
    data object Rejected : AdultPinResult
    data class Locked(val untilEpochMs: Long) : AdultPinResult
}

@Singleton
class FamilyProfileStore @Inject constructor(@ApplicationContext context: Context) {
    private val prefs = EncryptedSharedPreferences.create(
        context,
        "family_profiles.secure",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )
    private val json = Json { ignoreUnknownKeys = true }
    private val serializer = ListSerializer(FamilyProfile.serializer())
    private val defaultProfile = FamilyProfile(DEFAULT_ADULT_PROFILE_ID, "Adult", FamilyProfileRole.ADULT)
    private val _profiles = MutableStateFlow(loadProfiles())
    val profiles: StateFlow<List<FamilyProfile>> = _profiles.asStateFlow()
    val hasAdultPin: Boolean get() = prefs.contains("pin_hash")

    fun validPin(pin: String): Boolean = AdultPin.valid(pin)

    @Synchronized
    fun addChild(name: String): FamilyProfile {
        require(hasAdultPin)
        return add(name, FamilyProfileRole.CHILD)
    }

    @Synchronized
    fun addAdult(name: String): FamilyProfile = add(name, FamilyProfileRole.ADULT)

    private fun add(name: String, role: FamilyProfileRole): FamilyProfile {
        val profile = FamilyProfile(UUID.randomUUID().toString(), validatedName(name), role)
        val updated = _profiles.value + profile
        check(prefs.edit().putString("profiles", json.encodeToString(serializer, updated)).commit())
        _profiles.value = updated
        return profile
    }

    @Synchronized
    fun rename(profileId: String, name: String) {
        val trimmed = validatedName(name)
        require(_profiles.value.any { it.id == profileId })
        val updated = _profiles.value.map { if (it.id == profileId) it.copy(name = trimmed) else it }
        check(prefs.edit().putString("profiles", json.encodeToString(serializer, updated)).commit())
        _profiles.value = updated
    }

    @Synchronized
    fun remove(profileId: String) {
        require(profileId != DEFAULT_ADULT_PROFILE_ID)
        require(_profiles.value.any { it.id == profileId })
        val updated = _profiles.value.filterNot { it.id == profileId }
        check(prefs.edit().putString("profiles", json.encodeToString(serializer, updated)).commit())
        _profiles.value = updated
    }

    @Synchronized
    fun resetAdultPinAfterDeviceAuthentication(pin: String) {
        require(AdultPin.valid(pin))
        writeAdultPin(pin)
    }

    @Synchronized
    fun setAdultPin(pin: String, currentPin: String? = null): AdultPinResult {
        require(AdultPin.valid(pin))
        if (hasAdultPin) {
            val result = verifyAdultPin(currentPin.orEmpty())
            if (result != AdultPinResult.Accepted) return result
        }
        writeAdultPin(pin)
        return AdultPinResult.Accepted
    }

    private fun writeAdultPin(pin: String) {
        val (salt, hash) = AdultPin.create(pin)
        check(prefs.edit()
            .putString("pin_salt", salt.toHex())
            .putString("pin_hash", hash.toHex())
            .putInt("pin_failures", 0)
            .putLong("pin_locked_until", 0L)
            .commit())
    }

    @Synchronized
    fun verifyAdultPin(pin: String, nowEpochMs: Long = System.currentTimeMillis()): AdultPinResult {
        if (!hasAdultPin) return AdultPinResult.Rejected
        val lockedUntil = prefs.getLong("pin_locked_until", 0L)
        if (nowEpochMs < lockedUntil) return AdultPinResult.Locked(lockedUntil)
        val salt = prefs.getString("pin_salt", null)?.hexBytes() ?: return AdultPinResult.Rejected
        val hash = prefs.getString("pin_hash", null)?.hexBytes() ?: return AdultPinResult.Rejected
        if (AdultPin.matches(pin, salt, hash)) {
            check(prefs.edit().putInt("pin_failures", 0).putLong("pin_locked_until", 0L).commit())
            return AdultPinResult.Accepted
        }
        val failures = prefs.getInt("pin_failures", 0) + 1
        val until = nowEpochMs + pinLockoutMs(failures)
        check(prefs.edit().putInt("pin_failures", failures).putLong("pin_locked_until", until).commit())
        return if (until > nowEpochMs) AdultPinResult.Locked(until) else AdultPinResult.Rejected
    }

    private fun loadProfiles(): List<FamilyProfile> {
        val raw = prefs.getString("profiles", null) ?: return listOf(defaultProfile)
        val saved = json.decodeFromString(serializer, raw)
        check(saved.firstOrNull()?.let {
            it.id == DEFAULT_ADULT_PROFILE_ID && it.role == FamilyProfileRole.ADULT
        } == true)
        check(saved.map(FamilyProfile::id).distinct().size == saved.size)
        check(saved.all { FamilyProfile.validId(it.id) && it.name == validatedName(it.name) })
        return saved
    }

    private fun validatedName(name: String): String = name.trim().also {
        require(it.isNotEmpty() && it.length <= 40)
    }
}

private fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

private fun String.hexBytes(): ByteArray? =
    takeIf { it.length % 2 == 0 && it.all { char -> char in '0'..'9' || char in 'a'..'f' } }
        ?.chunked(2)?.map { it.toInt(16).toByte() }?.toByteArray()
