package com.enve.app.di

private val headerLine = Regex("^[A-Za-z0-9!#$%&'*+.^_`|~-]+\\s*:.*$")
private val urlInMessage = Regex("https?://[^\\s]+", RegexOption.IGNORE_CASE)

fun redactSensitiveHttpLogMessage(message: String): String {
    if (message.startsWith("<-- HTTP FAILED:")) return "<-- HTTP FAILED"
    if (headerLine.matches(message)) return "${message.substringBefore(':')}: [redacted]"
    return urlInMessage.replace(message, "[request URL]")
}
