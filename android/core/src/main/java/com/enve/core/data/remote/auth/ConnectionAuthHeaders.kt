// AGENT-LOCKED
package com.enve.core.data.remote.auth

import com.enve.core.data.model.ProviderConnection
import okhttp3.Request

fun Request.Builder.applyConnectionAuthHeaders(connection: ProviderConnection?): Request.Builder {
    if (connection == null) return this
    connection.customHeaders.forEach { (key, value) -> header(key, value) }
    if (connection.serviceClientId.isNotBlank()) header("CF-Access-Client-Id", connection.serviceClientId)
    if (connection.serviceClientSecret.isNotBlank()) header("CF-Access-Client-Secret", connection.serviceClientSecret)
    return this
}

fun ProviderConnection.hasCloudflareAccess(): Boolean {
    if (serviceClientId.isNotBlank() || serviceClientSecret.isNotBlank()) return true
    val cookie = customHeaders["Cookie"] ?: customHeaders["cookie"] ?: return false
    return cookie.contains("CF_Authorization=", ignoreCase = true)
}
