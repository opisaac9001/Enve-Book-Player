package com.enve.core.data.sync

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

data class KOReaderHubConfig(
    val serverUrl: String = "",
    val username: String = "",

    val passwordHash: String = "",
    val autoSyncEnabled: Boolean = true,
) {
    val isConfigured: Boolean
        get() = serverUrl.isNotBlank() && username.isNotBlank() && passwordHash.isNotBlank()

    val baseUrl: String?
        get() {
            var trimmed = serverUrl.trim()
            if (trimmed.isEmpty()) return null
            while (trimmed.endsWith("/")) trimmed = trimmed.dropLast(1)
            if (!trimmed.contains("://")) trimmed = "https://$trimmed"
            return trimmed.ifBlank { null }
        }
}

@Serializable
data class KOReaderProgress(
    val document: String = "",
    val progress: String = "",
    val percentage: Double = 0.0,
    val device: String = "",
    @SerialName("device_id")
    val deviceId: String = "",

    val timestamp: Long? = null,
)

@Serializable
data class KOReaderBookLink(
    val bookStableId: String,
    val documentHash: String,

    val isAutomatic: Boolean,
    val lastSyncedAt: Long? = null,
    val lastSyncedPercentage: Double? = null,
)
