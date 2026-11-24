package com.enve.app.data.offline

import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.security.MessageDigest

private const val RECOVERED_LOCAL_PREFIX = "local-recovered-"
private val importedLocalId = Regex("local-[A-Za-z0-9_-]{1,120}")

fun offlineDownloadKey(source: BookSource, connectionId: String?, bookId: String): String {
    if (isManagedLocalDownload(source, connectionId, bookId) && !isRecoveredLocalBookId(bookId)) {
        return bookId
    }
    return "dl-" + sha256(Json.encodeToString(listOf(source.name, connectionId, bookId)))
}

val Book.offlineDownloadKey: String get() = offlineDownloadKey(source, connectionId, id)

internal fun isManagedLocalDownload(source: BookSource, connectionId: String?, bookId: String): Boolean =
    source == BookSource.LOCAL && connectionId == null && importedLocalId.matches(bookId)

internal fun legacyOfflineDirectoryName(bookId: String): String = bookId.replace(Regex("[^a-zA-Z0-9_-]"), "_")

internal fun recoveredLocalBookId(format: String, directoryName: String): String =
    RECOVERED_LOCAL_PREFIX + sha256(Json.encodeToString(listOf(format, directoryName))).take(40)

internal fun isRecoveredLocalBookId(bookId: String): Boolean = bookId.startsWith(RECOVERED_LOCAL_PREFIX)

private fun sha256(value: String): String = MessageDigest.getInstance("SHA-256")
    .digest(value.toByteArray(Charsets.UTF_8))
    .joinToString("") { "%02x".format(it) }
