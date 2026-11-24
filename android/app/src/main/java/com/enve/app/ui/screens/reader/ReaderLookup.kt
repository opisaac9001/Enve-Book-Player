package com.enve.app.ui.screens.reader

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import okhttp3.HttpUrl
import java.util.Locale

internal object ReaderLookup {
    const val MAX_TRANSLATION_CHARS = 2_000
    const val MAX_WIKIPEDIA_CHARS = 100
    const val MAX_WIKIPEDIA_WORDS = 10

    private val whitespace = Regex("\\s+")
    private val languageTag = Regex("[a-z]{2,3}")
    private const val EDGE_PUNCTUATION = "\"'“”‘’«»„‚.,;:!?()[]{}<>…—–-*_"

    fun translationText(selection: String): String? =
        selection.replace(whitespace, " ").trim().takeIf { it.isNotEmpty() && it.length <= MAX_TRANSLATION_CHARS }

    fun wikipediaQuery(selection: String): String? {
        val query = selection.replace(whitespace, " ").trim().trim { it in EDGE_PUNCTUATION }.trim()
        if (query.isEmpty() || query.length > MAX_WIKIPEDIA_CHARS) return null
        if (query.split(' ').size > MAX_WIKIPEDIA_WORDS) return null
        return query
    }

    fun wikipediaUrl(query: String, locale: Locale): String = HttpUrl.Builder()
        .scheme("https")
        .host("${language(locale)}.wikipedia.org")
        .addPathSegment("wiki")
        .addPathSegment("Special:Search")
        .addQueryParameter("search", query)
        .addQueryParameter("go", "Go")
        .build()
        .toString()

    fun webTranslationUrl(text: String, locale: Locale): String = HttpUrl.Builder()
        .scheme("https")
        .host("translate.google.com")
        .addQueryParameter("sl", "auto")
        .addQueryParameter("tl", language(locale))
        .addQueryParameter("text", text)
        .addQueryParameter("op", "translate")
        .build()
        .toString()

    fun language(locale: Locale): String =
        locale.toLanguageTag().substringBefore('-').lowercase(Locale.ROOT)
            .takeIf { it != "und" && languageTag.matches(it) } ?: "en"

    fun openSystemTranslator(context: Context, text: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        return try {
            context.startActivity(Intent(Intent.ACTION_TRANSLATE).putExtra(Intent.EXTRA_TEXT, text))
            true
        } catch (_: ActivityNotFoundException) {
            false
        }
    }

    fun openInBrowser(context: Context, url: String): Boolean = try {
        context.startActivity(
            Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE),
        )
        true
    } catch (_: ActivityNotFoundException) {
        false
    }
}
