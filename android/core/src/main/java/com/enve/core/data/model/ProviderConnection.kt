package com.enve.core.data.model

import kotlinx.serialization.Serializable

@Serializable
data class ProviderConnection(
    val id: String,
    val source: BookSource,
    val name: String,
    val serverUrl: String,
    val username: String,
    val enabled: Boolean = true,
    val createdAt: Long = System.currentTimeMillis(),
    val lastSyncedAt: Long? = null,
    val needsReauth: Boolean = false,
    val authMode: ConnectionAuthMode = ConnectionAuthMode.AUTO,
    val urlScheme: UrlScheme = UrlScheme.HTTPS,
    val customHeaders: Map<String, String> = emptyMap(),
    val serviceClientId: String = "",
    val serviceClientSecret: String = "",
    val mtlsEnabled: Boolean = false,
    val cloudRootPaths: List<String> = emptyList(),

    val isAdmin: Boolean = false,
)
