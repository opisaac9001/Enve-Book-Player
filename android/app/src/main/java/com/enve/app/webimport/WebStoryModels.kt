package com.enve.app.webimport

import okhttp3.HttpUrl
import java.io.File

data class WebStoryMetadata(
    val title: String,
    val author: String?,
    val description: String?,
    val language: String,
    val sourceUrl: HttpUrl,
)

data class WebStoryChapterRef(val title: String, val url: HttpUrl)

class WebStoryPage(val url: HttpUrl, val bodyXhtml: String)

enum class WebStoryScope { THIS_CHAPTER, FROM_HERE, WHOLE_STORY }

sealed interface WebStoryPreview {
    val metadata: WebStoryMetadata

    data class Page(override val metadata: WebStoryMetadata, val page: WebStoryPage) : WebStoryPreview

    data class Serial(
        override val metadata: WebStoryMetadata,
        val chapters: List<WebStoryChapterRef>,
        val currentIndex: Int?,
        val currentPage: WebStoryPage?,
    ) : WebStoryPreview {
        val scopes: List<WebStoryScope>
            get() = if (currentIndex == null) {
                listOf(WebStoryScope.WHOLE_STORY)
            } else {
                listOf(WebStoryScope.THIS_CHAPTER, WebStoryScope.FROM_HERE, WebStoryScope.WHOLE_STORY)
            }

        val defaultScope: WebStoryScope
            get() = if (currentIndex == null) WebStoryScope.WHOLE_STORY else WebStoryScope.THIS_CHAPTER

        fun indices(scope: WebStoryScope): IntRange = when (scope) {
            WebStoryScope.THIS_CHAPTER -> checkNotNull(currentIndex).let { it..it }
            WebStoryScope.FROM_HERE -> checkNotNull(currentIndex)..chapters.lastIndex
            WebStoryScope.WHOLE_STORY -> chapters.indices
        }
    }

    data class Download(
        override val metadata: WebStoryMetadata,
        val file: File,
        val format: WebStoryFileFormat,
    ) : WebStoryPreview
}

data class WebStoryImportProgress(val completed: Int, val total: Int)

data class WebStoryImportResult(val file: File, val title: String, val chapters: Int)

class WebStoryImportException(
    val reason: Reason,
    val chapterTitle: String? = null,
    cause: Throwable? = null,
) : Exception(reason.message, cause) {

    val displayMessage: String
        get() = chapterTitle?.let { "$it: ${reason.message}" } ?: reason.message

    fun forChapter(title: String) = WebStoryImportException(reason, title, cause ?: this)

    enum class Reason(val message: String) {
        INVALID_URL("Paste a complete address that starts with http:// or https://."),
        ACCESS_DENIED("The site refused access. Use Open in browser for pages that need sign-in or verification."),
        BROWSER_CHECK("The site asked for a browser check. Use Open in browser to continue."),
        NOT_FOUND("The page couldn't be found."),
        RATE_LIMITED("The site is limiting requests. Wait a little and try again."),
        SERVER_ERROR("The site returned an error."),
        OFF_ORIGIN("The site sent Enve to a different website, so the import stopped."),
        UNSUPPORTED("That link isn't a web page, plain text or a supported ebook file."),
        TOO_LARGE("The page or file is larger than Enve imports."),
        NO_CONTENT("No readable text was found."),
        NO_CHAPTERS("No chapters were found for this story."),
        INTERACTIVE_INDEX("Open this story in the browser to read its interactive chapter list."),
        INDEX_INCOMPLETE("The story's chapter list couldn't be read completely."),
        CHAPTER_NOT_IN_INDEX("That chapter isn't in the story's chapter list."),
        STORY_TOO_LARGE("The story is larger than Enve can import at once."),
        NETWORK("The page couldn't be reached. Check the connection and try again."),
    }
}

enum class WebStoryFileFormat(
    val extension: String,
    private val mediaTypes: Set<String>,
    private val magicOffset: Int,
    private val magic: ByteArray,
) {
    EPUB("epub", setOf("application/epub+zip"), 0, byteArrayOf(0x50, 0x4B, 0x03, 0x04)),
    PDF("pdf", setOf("application/pdf"), 0, "%PDF-".toByteArray(Charsets.US_ASCII)),
    AZW3("azw3", setOf("application/vnd.amazon.ebook", "application/x-mobi8-ebook"), 60, "BOOKMOBI".toByteArray(Charsets.US_ASCII)),
    CBZ("cbz", setOf("application/vnd.comicbook+zip", "application/x-cbz"), 0, byteArrayOf(0x50, 0x4B, 0x03, 0x04)),
    CBR("cbr", setOf("application/vnd.comicbook-rar", "application/x-cbr"), 0, byteArrayOf(0x52, 0x61, 0x72, 0x21, 0x1a, 0x07));

    val headerLength: Int get() = magicOffset + magic.size

    fun matches(header: ByteArray): Boolean =
        header.size >= headerLength && magic.indices.all { header[magicOffset + it] == magic[it] }

    companion object {
        private val genericMediaTypes = setOf("application/octet-stream", "binary/octet-stream", "application/zip", "application/x-zip-compressed")

        fun detect(mediaType: String?, url: HttpUrl): WebStoryFileFormat? {
            entries.firstOrNull { mediaType in it.mediaTypes }?.let { return it }
            if (mediaType != null && mediaType !in genericMediaTypes) return null
            val name = url.pathSegments.lastOrNull().orEmpty().lowercase()
            if (name.endsWith(".kepub")) return EPUB
            return entries.firstOrNull { name.endsWith(".${it.extension}") }
        }
    }
}
