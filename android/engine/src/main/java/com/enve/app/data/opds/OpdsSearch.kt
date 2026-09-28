package com.enve.app.data.opds

import com.enve.app.data.repository.OpdsFeedParser
import com.enve.app.data.repository.isHttpUrl
import org.jsoup.Jsoup
import org.jsoup.parser.Parser
import java.net.URLEncoder

const val OPEN_SEARCH_MEDIA_TYPE = "application/opensearchdescription+xml"

fun isOpenSearchDescription(type: String): Boolean =
    type.substringBefore(';').trim().equals(OPEN_SEARCH_MEDIA_TYPE, ignoreCase = true)

fun parseOpenSearchTemplate(document: String, baseUrl: String): String? {
    val root = runCatching { Jsoup.parse(document, baseUrl, Parser.xmlParser()) }.getOrNull() ?: return null
    val urls = root.getElementsByTag("Url").ifEmpty { root.getElementsByTag("url") }
    val candidate = urls.firstOrNull { OpdsFeedParser.isTraversableFeedType(it.attr("type")) } ?: urls.firstOrNull()
    val template = candidate?.attr("template")?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    return OpdsFeedParser.resolve(baseUrl, template).takeIf { it.contains('{') || isHttpUrl(it) }
}

fun expandOpdsSearchTemplate(template: String, query: String): String {
    val expanded = StringBuilder()
    var index = 0
    while (index < template.length) {
        val open = template.indexOf('{', index)
        if (open < 0) {
            expanded.append(template, index, template.length)
            break
        }
        val close = template.indexOf('}', open)
        if (close < 0) {
            expanded.append(template, index, template.length)
            break
        }
        expanded.append(template, index, open)
        expanded.append(expandExpression(template.substring(open + 1, close), query))
        index = close + 1
    }
    return expanded.toString()
}

private fun expandExpression(expression: String, query: String): String {
    val operator = expression.firstOrNull()?.takeIf { it in "?&+#/.;=,!@|" }
    val variables = (if (operator == null) expression else expression.drop(1))
        .split(',')
        .map { it.trim().removeSuffix("?") }
        .filter { it.isNotEmpty() }
    if (variables.isEmpty()) return ""

    return when (operator) {
        '?', '&' -> {
            val name = variables.firstOrNull(::isSearchTermsVariable) ?: return ""
            val prefix = if (operator == '?') "?" else "&"
            "$prefix${encode(name.substringAfterLast(':'))}=${encode(query)}"
        }

        '+', '#' -> if (variables.any(::isSearchTermsVariable)) query else ""
        null -> if (variables.any(::isSearchTermsVariable)) encode(query) else ""
        else -> ""
    }
}

private fun isSearchTermsVariable(name: String): Boolean =
    name.substringAfterLast(':').lowercase() in searchTermsVariables

private fun encode(value: String): String =
    URLEncoder.encode(value, "UTF-8").replace("+", "%20")

private val searchTermsVariables = setOf("searchterms", "query", "q", "search", "keywords", "title")
