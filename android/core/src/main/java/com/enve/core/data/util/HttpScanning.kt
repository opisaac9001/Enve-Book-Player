package com.enve.core.data.util

import com.enve.core.data.model.AppMediaType
import java.net.URI

fun extractXmlTag(xml: String, tag: String): String? {
    val regex = Regex("<$tag\\b[^>]*>([\\s\\S]*?)</$tag>", RegexOption.IGNORE_CASE)
    return regex.find(xml)?.groupValues?.getOrNull(1)?.trim()?.takeIf { it.isNotBlank() }
}

fun extractHtmlAttr(tag: String, attrName: String): String? {
    val regex = Regex("\\b$attrName\\s*=\\s*[\"']([^\"']+)[\"']", RegexOption.IGNORE_CASE)
    return regex.find(tag)?.groupValues?.getOrNull(1)?.trim()?.takeIf { it.isNotBlank() }
}

fun resolveAgainst(baseUrl: String, maybeRelative: String): String {
    return try {
        val href = maybeRelative.trim()
        when {
            href.startsWith("http://") || href.startsWith("https://") -> href
            href.startsWith("//") -> "https:$href"
            else -> {
                val base = URI(baseUrl)
                base.resolve(href).toString()
            }
        }
    } catch (_: Exception) {
        maybeRelative
    }
}

fun stripXmlTags(input: String): String {
    return input.replace(Regex("<[^>]+>"), " ").replace(Regex("\\s+"), " ").trim()
}

fun decodeXmlEntities(input: String): String {
    return input
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
}

fun inferMediaTypeFromPath(path: String, defaultType: AppMediaType = AppMediaType.EBOOK): AppMediaType {
    val ext = path.substringBefore('?').substringAfterLast('.', "").lowercase()
    return when (ext) {
        "m4b", "mp3", "aac", "flac", "ogg" -> AppMediaType.AUDIOBOOK
        "epub", "pdf", "cbz", "cbr", "cbx", "mobi", "azw3", "fb2" -> AppMediaType.EBOOK
        else -> defaultType
    }
}

fun titleFromPrimaryFileName(fileNameOrPath: String?): String? {
    val trimmed = fileNameOrPath?.trim()?.takeIf { it.isNotBlank() } ?: return null
    val fileName = trimmed.substringAfterLast('/').substringAfterLast('\\')
    return fileName.substringBeforeLast('.', fileName).trim().takeIf { it.isNotBlank() }
}
