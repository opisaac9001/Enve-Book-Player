package com.enve.engine.profiles

import android.content.Intent
import com.enve.core.data.local.AdultPinResult
import com.enve.core.data.local.FamilyProfile
import com.enve.core.data.local.FamilyProfileRole
import com.enve.core.data.model.Book
import kotlinx.coroutines.flow.StateFlow

data class ProfilesUiState(
    val enabled: Boolean = false,
    val activeProfileId: String? = null,
    val profiles: List<FamilyProfile> = emptyList(),
    val switching: Boolean = false,
    val locked: Boolean = false,
    val parentAuthorized: Boolean = false,
    val error: String? = null,
    val serverSyncEnabled: Map<String, Boolean> = emptyMap(),
)

enum class ProfileDownloadFormat { AUDIOBOOK, EBOOK }

data class ProfileDownloadCandidate(
    val sourceProfileId: String,
    val bookKey: String,
    val title: String,
    val author: String?,
    val format: ProfileDownloadFormat,
)

interface ProfilesFacade {
    val state: StateFlow<ProfilesUiState>

    suspend fun setupOwner(name: String, pin: String? = null, confirmation: String? = null, serverSyncEnabled: Boolean? = null)
    suspend fun disableProfiles()
    suspend fun addProfile(name: String, role: FamilyProfileRole, pin: String? = null, serverSyncEnabled: Boolean = false): FamilyProfile
    suspend fun renameProfile(profileId: String, name: String, pin: String? = null)
    suspend fun setServerSyncEnabled(profileId: String, enabled: Boolean, pin: String? = null)
    suspend fun removeProfile(profileId: String, pin: String? = null)
    suspend fun verifyAdultPin(pin: String): AdultPinResult
    suspend fun switchProfile(profileId: String, pin: String? = null)
    suspend fun importCandidates(sourceProfileId: String, pin: String? = null): List<ProfileDownloadCandidate>
    suspend fun importCompleted(
        sourceProfileId: String,
        targetProfileId: String,
        bookKey: String,
        format: ProfileDownloadFormat,
        pin: String? = null,
    ): Book
    suspend fun changeAdultPin(currentPin: String?, newPin: String, confirmation: String)
    fun pinRecoveryIntent(): Intent?
    suspend fun resetAdultPinAfterDeviceAuthentication(newPin: String, confirmation: String)
    fun onBackground()
    fun clearError()
}
