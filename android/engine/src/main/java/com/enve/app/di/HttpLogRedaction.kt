package com.enve.app.di

private val sensitiveHeaderRegex = Regex(
    "^(Authorization|Cookie|Set-Cookie|X-Plex-Token|X-Emby-Token)\\s*:.*$",
    RegexOption.IGNORE_CASE,
)

private val sensitiveQueryRegex = Regex(
    "([?&](?:X-Plex-Token|token|access_token|refresh_token|api_key|apikey|auth|authorization)=)[^&\\s]+",
    RegexOption.IGNORE_CASE,
)

fun redactSensitiveHttpLogMessage(message: String): String {
    if (sensitiveHeaderRegex.matches(message)) {
        return "${message.substringBefore(':')}: [redacted]"
    }
    return sensitiveQueryRegex.replace(message) { match ->
        match.groupValues[1] + "[redacted]"
    }
}
