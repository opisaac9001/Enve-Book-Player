package com.enve.core.data.remote

object NetworkErrorMapper {
    private val htmlHints = listOf(
        "web page instead of data",
        "<!doctype html",
        "<html",
        "unexpected json token",
        "expected start of the object",
    )

    fun isLikelyHtmlResponseError(message: String?): Boolean {
        val text = message?.lowercase() ?: return false
        return htmlHints.any { it in text }
    }

    fun mapForUser(message: String?): String {
        val raw = message?.trim().orEmpty()
        if (raw.isBlank()) return "Unable to connect to the server. Please try again."
        if (isLikelyHtmlResponseError(raw)) {
            return "The server returned a web page instead of API data. Sign in again, then verify the server URL points to the correct API host."
        }
        return raw
    }
}
