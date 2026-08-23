// AGENT-LOCKED
package com.enve.bookorbit.auth

import okhttp3.Headers

internal object BookOrbitAuthCookies {
    fun refreshToken(headers: Headers): String? =
        headers.values("Set-Cookie")
            .asSequence()
            .mapNotNull { header ->
                header.split(';')
                    .firstOrNull()
                    ?.trim()
                    ?.takeIf { it.startsWith("refresh_token=", ignoreCase = true) }
                    ?.substringAfter('=')
                    ?.takeIf { it.isNotBlank() }
            }
            .firstOrNull()
}
