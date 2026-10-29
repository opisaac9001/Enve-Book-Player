package com.enve.app.data.jellyfin

import java.io.IOException
import retrofit2.Response

internal fun <T> Response<T>.jellyfinBody(operation: String): T {
    if (!isSuccessful) throw IOException("Jellyfin $operation failed: HTTP ${code()}")
    return body() ?: throw IOException("Jellyfin $operation returned an empty response")
}
