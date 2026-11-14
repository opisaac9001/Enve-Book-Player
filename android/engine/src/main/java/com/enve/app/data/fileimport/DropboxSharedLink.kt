package com.enve.app.data.fileimport

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.URI
import java.net.URISyntaxException
import java.security.MessageDigest

class DropboxSharedLink private constructor(
    internal val downloadUrl: HttpUrl,
    val fileName: String,
    val identity: String,
) {
    override fun toString(): String = "DropboxSharedLink($fileName)"

    companion object {
        const val INVALID_LINK = "Paste a Dropbox file link that starts with https://www.dropbox.com/."
        const val FILE_LINKS_ONLY = "Only Dropbox links to a single file can be imported. Folder and shortened links aren't supported."
        const val UNSUPPORTED_FILE = "That Dropbox link isn't a supported audiobook or ebook file."

        private val initialHosts = setOf("www.dropbox.com", "dropbox.com")
        private val shareId = Regex("[A-Za-z0-9_-]{1,128}")
        private val forbiddenNameCharacters = Regex("""[\\/:*?"<>|]""")
        private const val MAX_LINK_LENGTH = 4_096
        private const val MAX_STEM_LENGTH = 120

        fun parse(input: String): DropboxSharedLink {
            val text = input.trim()
            require(text.length in 1..MAX_LINK_LENGTH && text.none { it.isWhitespace() || it.isISOControl() }) { INVALID_LINK }
            val uri = try {
                URI(text)
            } catch (_: URISyntaxException) {
                throw IllegalArgumentException(INVALID_LINK)
            }
            require(uri.scheme.equals("https", ignoreCase = true)) { INVALID_LINK }
            require(uri.rawUserInfo == null && uri.port == -1 && uri.rawFragment == null) { INVALID_LINK }
            require(uri.host?.lowercase()?.let(initialHosts::contains) == true) { INVALID_LINK }
            val url = requireNotNull(text.toHttpUrlOrNull()) { INVALID_LINK }
            val segments = url.pathSegments
            val (id, rawName) = when {
                segments.size == 3 && segments[0] == "s" -> segments[1] to segments[2]
                segments.size == 4 && segments[0] == "scl" && segments[1] == "fi" -> segments[2] to segments[3]
                else -> throw IllegalArgumentException(FILE_LINKS_ONLY)
            }
            require(shareId.matches(id)) { FILE_LINKS_ONLY }
            val name = requireNotNull(sanitizedFileName(rawName)) { UNSUPPORTED_FILE }
            require(ImportableFormats.kind(name) != null) { UNSUPPORTED_FILE }
            val pathDigest = MessageDigest.getInstance("SHA-256")
                .digest(url.encodedPath.toByteArray())
                .joinToString("") { "%02x".format(it) }
            return DropboxSharedLink(
                downloadUrl = url.newBuilder().setQueryParameter("dl", "1").build(),
                fileName = name,
                identity = "dropbox-link:$pathDigest",
            )
        }

        internal fun sanitizedFileName(raw: String): String? {
            val cleaned = raw.filterNot { it.isISOControl() }
                .replace(forbiddenNameCharacters, "_")
                .trim()
                .trimStart('.')
            val extension = ImportableFormats.extension(cleaned)
            val stem = ImportableFormats.stem(cleaned).take(MAX_STEM_LENGTH).trim()
            if (extension.isEmpty() || stem.isEmpty()) return null
            return "$stem.$extension"
        }
    }
}
