package com.enve.app.webimport

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import org.jsoup.nodes.Document
import org.jsoup.nodes.Element

internal object WebStoryExtractor {
    private const val MAX_TITLE_LENGTH = 300
    private const val MAX_AUTHOR_LENGTH = 200
    private const val MAX_DESCRIPTION_LENGTH = 4000

    private const val INDEX_LINKS = "#chapters a[href], .chapter-row a[href], a.chapter-row[href]"
    private const val NEXT_LINK = "link[rel~=(?i)(^|\\s)next(\\s|$)][href], a[rel~=(?i)(^|\\s)next(\\s|$)][href]"
    private const val PARENT_LINK =
        "link[rel~=(?i)(^|\\s)(index|up|contents|toc)(\\s|$)][href], a[rel~=(?i)(^|\\s)(index|up|contents|toc)(\\s|$)][href]"

    private val contentSelectors = listOf(
        ".chapter-inner.chapter-content",
        ".chapter-content",
        "[itemprop=articleBody]",
        ".entry-content",
        ".post-content",
        ".article-body",
        "article",
        "main",
        "[role=main]",
        "#content",
    )
    private val languageTag = Regex("^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$")
    private val cssRule = Regex("([^{}]+)\\{([^}]*)\\}")
    private val displayNone = Regex("display\\s*:\\s*none", RegexOption.IGNORE_CASE)
    private val classSelector = Regex("^\\.(-?[A-Za-z_][\\w-]*)$")

    class ChapterLink(val id: String, val title: String?, val url: HttpUrl)

    fun metadata(doc: Document, url: HttpUrl): WebStoryMetadata = WebStoryMetadata(
        title = WebStorySanitizer.plainText(
            doc.selectFirst(".fic-title h1")?.text()
                ?: doc.meta("og:title", "twitter:title")
                ?: doc.selectFirst("h1")?.text()
                ?: doc.title(),
            MAX_TITLE_LENGTH,
        ) ?: url.host,
        author = WebStorySanitizer.plainText(
            doc.meta("books:author", "author", "article:author")?.takeUnless { it.startsWith("http") }
                ?: doc.selectFirst(".fic-title h4 a, [rel=author], [itemprop=author]")?.text(),
            MAX_AUTHOR_LENGTH,
        ),
        description = doc.selectFirst(".description .hidden-content")
            ?.let { block -> block.select("p").eachText().joinToString("\n\n").ifBlank { block.text() } }
            ?.let { WebStorySanitizer.xmlSafe(it).trim().take(MAX_DESCRIPTION_LENGTH).ifBlank { null } }
            ?: WebStorySanitizer.plainText(doc.meta("og:description", "description"), MAX_DESCRIPTION_LENGTH),
        language = doc.selectFirst("html[lang]")?.attr("lang")?.trim()?.takeIf { languageTag.matches(it) } ?: "und",
        sourceUrl = url,
    )

    fun content(doc: Document): Element =
        contentSelectors.firstNotNullOfOrNull { selector -> doc.selectFirst(selector)?.takeIf { it.hasText() } }
            ?: doc.body()

    fun chapterLinks(doc: Document, pageUrl: HttpUrl, fictionId: String?): List<ChapterLink> =
        doc.select(INDEX_LINKS).mapNotNull { link ->
            val url = link.absUrl("href").toHttpUrlOrNull()?.let(WebStoryUrls::withoutFragment)
                ?.takeIf { WebStoryUrls.sameOrigin(it, pageUrl) }
                ?.takeIf { fictionId == null || it.encodedPath.startsWith("/fiction/$fictionId/") || it.encodedPath.startsWith("/fiction/chapter/") }
                ?: return@mapNotNull null
            val id = WebStoryUrls.chapterId(url) ?: return@mapNotNull null
            ChapterLink(id, WebStorySanitizer.plainText(link.text(), MAX_TITLE_LENGTH), url)
        }

    fun nextIndexPage(doc: Document): String? {
        doc.selectFirst(NEXT_LINK)?.let { return it.absUrl("href") }
        val pager = doc.getElementById("chapters")?.parent()?.selectFirst("ul.pagination-small") ?: return null
        val next = pager.selectFirst(".nav-arrow:not(.disabled) a:has(.fa-chevron-right)") ?: return null
        return next.absUrl("href").takeUnless { it.isBlank() || next.attr("href").startsWith("#") }
            ?: throw WebStoryImportException(WebStoryImportException.Reason.INTERACTIVE_INDEX)
    }

    fun parentIndex(doc: Document): String? = doc.selectFirst(PARENT_LINK)?.absUrl("href")

    fun hiddenClasses(doc: Document): Set<String> = buildSet {
        for (style in doc.select("style")) {
            for (rule in cssRule.findAll(style.data())) {
                if (!displayNone.containsMatchIn(rule.groupValues[2])) continue
                rule.groupValues[1].split(',').forEach { part ->
                    classSelector.matchEntire(part.trim())?.let { add(it.groupValues[1]) }
                }
            }
        }
    }

    private fun Document.meta(vararg keys: String): String? = keys.firstNotNullOfOrNull { key ->
        selectFirst("meta[property=\"$key\"][content], meta[name=\"$key\"][content]")
            ?.attr("content")
            ?.trim()
            ?.ifBlank { null }
    }
}
