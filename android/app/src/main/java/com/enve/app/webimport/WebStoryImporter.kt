package com.enve.app.webimport

import com.enve.app.webimport.WebStoryImportException.Reason
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import java.io.File
import java.time.Instant
import java.util.UUID

internal class WebStoryImporter(
    client: OkHttpClient = WebPageFetcher.defaultClient(),
    private val limits: WebStoryLimits = WebStoryLimits(),
    private val requestSpacingMs: Long = 500,
) {
    private val fetcher = WebPageFetcher(client, limits)

    suspend fun preview(input: String, workDir: File): WebStoryPreview = withContext(Dispatchers.IO) {
        val url = WebStoryUrls.parseInput(input)
        val budget = WebFetchBudget(limits)
        val fictionId = WebStoryUrls.royalRoadFictionId(url)
        if (fictionId != null) {
            val index = fetcher.fetchDocument(WebStoryUrls.royalRoadFictionUrl(url, fictionId), budget, origin = null)
            return@withContext serial(index, budget, fictionId, WebStoryUrls.chapterId(url), currentPage = null)
        }
        when (val fetched = fetcher.fetchEntry(url, budget, workDir)) {
            is WebFetched.Html -> previewHtml(fetched, budget)
            is WebFetched.Text -> previewText(fetched)
            is WebFetched.Ebook -> WebStoryPreview.Download(fileMetadata(fetched.url), fetched.file, fetched.format)
        }
    }

    suspend fun previewCaptured(url: String, html: String): WebStoryPreview = withContext(Dispatchers.Default) {
        val pageUrl = WebStoryUrls.parseInput(url)
        if (html.length > limits.maxPageBytes) throw WebStoryImportException(Reason.TOO_LARGE)
        val doc = Jsoup.parse(html, pageUrl.toString())
        val chapterId = WebStoryUrls.chapterId(pageUrl)
        val fictionId = WebStoryUrls.royalRoadFictionId(pageUrl)
        if (WebStoryExtractor.chapterLinks(doc, pageUrl, fictionId).isNotEmpty()) {
            val current = chapterId?.let { snapshot(doc, pageUrl, null) }
            return@withContext serial(WebFetched.Html(pageUrl, doc), WebFetchBudget(limits), fictionId, chapterId, current)
        }
        val metadata = WebStoryExtractor.metadata(doc, pageUrl)
        WebStoryPreview.Page(metadata, snapshot(doc, pageUrl, metadata.title))
    }

    suspend fun import(
        preview: WebStoryPreview,
        scope: WebStoryScope,
        workDir: File,
        onProgress: (WebStoryImportProgress) -> Unit,
    ): WebStoryImportResult = withContext(Dispatchers.IO) {
        when (preview) {
            is WebStoryPreview.Download -> WebStoryImportResult(preview.file, preview.metadata.title, chapters = 0)
            is WebStoryPreview.Page -> buildEpub(preview.metadata, workDir) { writer ->
                writer.addChapter(preview.metadata.title, preview.page.bodyXhtml, preview.metadata.language, preview.page.url)
                onProgress(WebStoryImportProgress(1, 1))
            }
            is WebStoryPreview.Serial -> buildEpub(preview.metadata, workDir) { writer ->
                val indices = preview.indices(scope)
                val total = indices.last - indices.first + 1
                val budget = WebFetchBudget(limits)
                indices.forEachIndexed { position, index ->
                    val ref = preview.chapters[index]
                    val page = if (index == preview.currentIndex && preview.currentPage != null) {
                        preview.currentPage
                    } else {
                        if (position > 0) delay(requestSpacingMs)
                        fetchChapter(ref, budget, preview.metadata.sourceUrl)
                    }
                    writer.addChapter(ref.title, page.bodyXhtml, preview.metadata.language, page.url)
                    onProgress(WebStoryImportProgress(position + 1, total))
                }
            }
        }
    }

    private suspend fun previewHtml(page: WebFetched.Html, budget: WebFetchBudget): WebStoryPreview {
        val doc = page.document
        val chapterId = WebStoryUrls.chapterId(page.url)
        if (WebStoryExtractor.chapterLinks(doc, page.url, fictionId = null).isNotEmpty()) {
            return serial(page, budget, null, chapterId, chapterId?.let { snapshot(doc, page.url, null) })
        }
        val metadata = WebStoryExtractor.metadata(doc, page.url)
        val current = snapshot(doc, page.url, metadata.title)
        val parent = chapterId?.let { WebStoryExtractor.parentIndex(doc) }
            ?.toHttpUrlOrNull()
            ?.let(WebStoryUrls::withoutFragment)
            ?.takeIf { WebStoryUrls.sameOrigin(it, page.url) }
            ?: return WebStoryPreview.Page(metadata, current)
        return serial(fetcher.fetchDocument(parent, budget, origin = page.url), budget, null, chapterId, current)
    }

    private suspend fun serial(
        first: WebFetched.Html,
        budget: WebFetchBudget,
        fictionId: String?,
        currentId: String?,
        currentPage: WebStoryPage?,
    ): WebStoryPreview.Serial {
        val origin = first.url
        val chapters = LinkedHashMap<String, WebStoryChapterRef>()
        val visited = HashSet<HttpUrl>()
        var page = first
        while (true) {
            if (!visited.add(page.url)) throw WebStoryImportException(Reason.INDEX_INCOMPLETE)
            for (link in WebStoryExtractor.chapterLinks(page.document, page.url, fictionId)) {
                if (link.id in chapters) continue
                if (chapters.size >= limits.maxChapters) throw WebStoryImportException(Reason.STORY_TOO_LARGE)
                chapters[link.id] = WebStoryChapterRef(link.title ?: "Chapter ${chapters.size + 1}", link.url)
            }
            val next = WebStoryExtractor.nextIndexPage(page.document) ?: break
            val nextUrl = next.toHttpUrlOrNull()
                ?.let(WebStoryUrls::withoutFragment)
                ?.takeIf { WebStoryUrls.sameOrigin(it, origin) && it !in visited }
                ?: throw WebStoryImportException(Reason.INDEX_INCOMPLETE)
            if (visited.size >= limits.maxIndexPages) throw WebStoryImportException(Reason.STORY_TOO_LARGE)
            delay(requestSpacingMs)
            page = fetcher.fetchDocument(nextUrl, budget, origin)
        }
        if (chapters.isEmpty()) throw WebStoryImportException(Reason.NO_CHAPTERS)
        val currentIndex = currentId?.let { id ->
            chapters.keys.indexOf(id).takeIf { it >= 0 } ?: throw WebStoryImportException(Reason.CHAPTER_NOT_IN_INDEX)
        }
        return WebStoryPreview.Serial(
            metadata = WebStoryExtractor.metadata(first.document, first.url),
            chapters = chapters.values.toList(),
            currentIndex = currentIndex,
            currentPage = currentPage,
        )
    }

    private suspend fun fetchChapter(ref: WebStoryChapterRef, budget: WebFetchBudget, origin: HttpUrl): WebStoryPage =
        try {
            val page = fetcher.fetchDocument(ref.url, budget, origin)
            snapshot(page.document, page.url, ref.title)
        } catch (e: WebStoryImportException) {
            throw e.forChapter(ref.title)
        }

    private fun previewText(text: WebFetched.Text): WebStoryPreview.Page {
        val body = text.text.split(blankLine).mapNotNull { block ->
            block.lines()
                .map { WebStoryEpubWriter.escape(it.trim()) }
                .filter { it.isNotEmpty() }
                .takeIf { it.isNotEmpty() }
                ?.joinToString("<br />", prefix = "<p>", postfix = "</p>")
        }
        if (body.isEmpty()) throw WebStoryImportException(Reason.NO_CONTENT)
        return WebStoryPreview.Page(fileMetadata(text.url), WebStoryPage(text.url, body.joinToString("")))
    }

    private fun fileMetadata(url: HttpUrl) = WebStoryMetadata(
        title = WebStorySanitizer.plainText(url.pathSegments.lastOrNull()?.substringBeforeLast('.'), MAX_TITLE_LENGTH) ?: url.host,
        author = null,
        description = null,
        language = "und",
        sourceUrl = url,
    )

    private fun snapshot(doc: Document, url: HttpUrl, title: String?): WebStoryPage {
        val body = WebStorySanitizer.sanitize(WebStoryExtractor.content(doc), url, WebStoryExtractor.hiddenClasses(doc), title)
            ?: throw WebStoryImportException(Reason.NO_CONTENT)
        return WebStoryPage(url, body)
    }

    private inline fun buildEpub(metadata: WebStoryMetadata, workDir: File, write: (WebStoryEpubWriter) -> Unit): WebStoryImportResult {
        workDir.mkdirs()
        val file = File(workDir, "${UUID.randomUUID()}.epub")
        try {
            val chapters = WebStoryEpubWriter(file, limits.maxEpubBytes).use { writer ->
                write(writer)
                writer.finish(metadata, Instant.now())
                writer.chapterCount
            }
            return WebStoryImportResult(file, metadata.title, chapters)
        } catch (e: Throwable) {
            file.delete()
            throw e
        }
    }

    private companion object {
        const val MAX_TITLE_LENGTH = 300
        val blankLine = Regex("\\r?\\n[ \\t]*\\r?\\n")
    }
}
