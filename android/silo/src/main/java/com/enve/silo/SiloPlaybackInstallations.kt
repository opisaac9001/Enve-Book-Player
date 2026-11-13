package com.enve.silo

import com.enve.silo.api.SiloApi
import com.enve.silo.dto.SiloPlaybackCapabilitiesDto
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

internal const val SILO_SEQUENCED_PROGRESS = "sequenced_progress_v1"
internal const val SILO_INSTALLATION_CHANGED = "installation_changed"

internal fun SiloPlaybackCapabilitiesDto.installation(): String {
    if (state != "available" || allowed == false) error("Silo playback is unavailable for this profile")
    if (3 !in protocolVersions || SILO_SEQUENCED_PROGRESS !in features) {
        error("This Silo server does not support sequenced audio playback")
    }
    return installationId?.takeIf { it.isNotBlank() } ?: error("Silo did not report a playback installation")
}

@Singleton
class SiloPlaybackInstallations @Inject constructor(
    private val api: SiloApi,
) {
    private val installations = ConcurrentHashMap<String, String>()

    suspend fun current(connectionKey: String, profileId: String): String =
        installations[connectionKey] ?: api.playbackCapabilities(profileId)
            .siloBody("Silo playback capabilities failed")
            .installation()
            .also { installations[connectionKey] = it }

    fun forget(connectionKey: String) {
        installations.remove(connectionKey)
    }

    fun clear() = installations.clear()
}
