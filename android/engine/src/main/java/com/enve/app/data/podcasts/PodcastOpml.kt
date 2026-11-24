package com.enve.app.data.podcasts

import com.enve.engine.podcasts.PodcastFeedUrl
import com.enve.engine.podcasts.PodcastOpmlEpisode
import com.enve.engine.podcasts.PodcastOpmlError
import com.enve.engine.podcasts.PodcastOpmlException
import com.enve.engine.podcasts.PodcastOpmlLimits
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.SAXException
import org.xml.sax.helpers.DefaultHandler
import java.io.StringReader
import java.net.URI
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.time.Instant
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import javax.xml.parsers.SAXParserFactory

internal data class PodcastOpmlFeed(
    val title: String,
    val feedUrl: String,
    val isSubscribed: Boolean = true,
    val episodes: List<PodcastOpmlEpisode> = emptyList(),
)

internal data class PodcastOpmlDocument(val feeds: List<PodcastOpmlFeed>, val invalidFeedCount: Int)

internal data class PodcastOpmlExportFeed(val title: String, val feedUrl: String, val episodes: List<PodcastOpmlEpisode>)

internal object PodcastOpmlParser {
    private val forbiddenMarkers = listOf("<!doctype", "<!entity")
    private val hardeningFeatures = listOf(
        "http://apache.org/xml/features/disallow-doctype-decl" to true,
        "http://xml.org/sax/features/external-general-entities" to false,
        "http://xml.org/sax/features/external-parameter-entities" to false,
        "http://apache.org/xml/features/nonvalidating/load-external-dtd" to false,
    )

    fun parse(bytes: ByteArray): PodcastOpmlDocument {
        if (bytes.isEmpty()) throw PodcastOpmlException(PodcastOpmlError.EMPTY)
        if (bytes.size > PodcastOpmlLimits.MAX_BYTES) throw PodcastOpmlException(PodcastOpmlError.TOO_LARGE)
        val prefix = bytes.take(4)
        val isUtf16 = prefix.size >= 2 && ((prefix[0] == 0xFE.toByte() && prefix[1] == 0xFF.toByte()) ||
            (prefix[0] == 0xFF.toByte() && prefix[1] == 0xFE.toByte()))
        if (isUtf16 || prefix.contains(0)) throw PodcastOpmlException(PodcastOpmlError.UNSUPPORTED_ENCODING)
        val text = try {
            Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (_: CharacterCodingException) {
            throw PodcastOpmlException(PodcastOpmlError.UNSUPPORTED_ENCODING)
        }
        if (forbiddenMarkers.any { text.contains(it, ignoreCase = true) }) {
            throw PodcastOpmlException(PodcastOpmlError.DOCUMENT_TYPE_NOT_ALLOWED)
        }

        val factory = SAXParserFactory.newInstance().apply { isNamespaceAware = false }
        for ((feature, value) in hardeningFeatures) {
            try {
                factory.setFeature(feature, value)
            } catch (_: Exception) {
            }
        }
        val handler = OpmlHandler()
        try {
            factory.newSAXParser().parse(InputSource(StringReader(text.removePrefix("﻿"))), handler)
        } catch (abort: Abort) {
            throw PodcastOpmlException(abort.error)
        } catch (_: SAXException) {
            throw PodcastOpmlException(PodcastOpmlError.MALFORMED)
        }
        if (!handler.sawRoot) throw PodcastOpmlException(PodcastOpmlError.NOT_OPML)
        val feeds = handler.parsedFeeds
        if (feeds.isEmpty()) throw PodcastOpmlException(PodcastOpmlError.NO_FEEDS)
        return PodcastOpmlDocument(feeds, handler.invalidFeedCount)
    }

    private class Abort(val error: PodcastOpmlError) : SAXException(error.message)

    private class OpmlHandler : DefaultHandler() {
        private val feeds = mutableListOf<PodcastOpmlFeed>()
        private val episodes = mutableListOf<MutableList<PodcastOpmlEpisode>>()
        val parsedFeeds: List<PodcastOpmlFeed> get() = feeds.mapIndexed { index, feed -> feed.copy(episodes = episodes[index]) }
        var invalidFeedCount = 0
        var sawRoot = false
        private val frames = ArrayDeque<Int>()
        private var outlineCount = 0

        override fun resolveEntity(publicId: String?, systemId: String?): InputSource = InputSource(StringReader(""))

        override fun startElement(uri: String, localName: String, qName: String, attributes: Attributes) {
            if (frames.size >= PodcastOpmlLimits.MAX_DEPTH) throw Abort(PodcastOpmlError.TOO_COMPLEX)
            val name = qName.lowercase(Locale.ROOT)
            if (!sawRoot) {
                if (name != "opml") throw Abort(PodcastOpmlError.NOT_OPML)
                sawRoot = true
                frames.addLast(OTHER)
                return
            }
            if (name != "outline") {
                frames.addLast(OTHER)
                return
            }
            if (++outlineCount > PodcastOpmlLimits.MAX_OUTLINES) throw Abort(PodcastOpmlError.TOO_COMPLEX)

            val values = HashMap<String, String>(attributes.length)
            for (index in 0 until attributes.length) {
                values.putIfAbsent(attributes.getQName(index).lowercase(Locale.ROOT), attributes.getValue(index))
            }
            val rawFeedUrl = values["xmlurl"]
            if (rawFeedUrl != null) {
                val feedUrl = PodcastFeedUrl.canonical(rawFeedUrl)
                if (feedUrl == null) {
                    invalidFeedCount++
                    frames.addLast(OTHER)
                    return
                }
                if (feeds.size >= PodcastOpmlLimits.MAX_FEEDS) throw Abort(PodcastOpmlError.TOO_COMPLEX)
                feeds += PodcastOpmlFeed(
                    title = nonEmpty(values["title"]) ?: nonEmpty(values["text"]) ?: URI(feedUrl).host ?: feedUrl,
                    feedUrl = feedUrl,
                    isSubscribed = values["subscribed"]?.let(::isTrue) ?: true,
                )
                episodes += mutableListOf<PodcastOpmlEpisode>()
                frames.addLast(feeds.lastIndex)
                return
            }

            val feedIndex = frames.lastOrNull { it != OTHER }
            if (feedIndex != null && isEpisode(values)) episodes[feedIndex] += episode(values)
            frames.addLast(OTHER)
        }

        override fun endElement(uri: String, localName: String, qName: String) {
            frames.removeLastOrNull()
        }

        private fun isEpisode(values: Map<String, String>) =
            values["type"]?.lowercase(Locale.ROOT) == "podcast-episode" || values["enclosureurl"] != null

        private fun episode(values: Map<String, String>) = PodcastOpmlEpisode(
            title = nonEmpty(values["title"]) ?: nonEmpty(values["text"]),
            guid = nonEmpty(values["guid"]),
            enclosureUrl = nonEmpty(values["enclosureurl"]),
            publishedAtMs = values["pubdate"]?.let(PodcastFeedParser::parseDate),
            updatedAtMs = values["userupdateddate"]?.let(PodcastFeedParser::parseDate),
            positionSec = values["progress"]?.trim()?.toDoubleOrNull()?.takeIf { it.isFinite() && it > 0.0 }?.toLong(),
            isPlayed = values["played"]?.let(::isTrue) ?: false,
        )

        private fun isTrue(value: String) = value.trim().lowercase(Locale.ROOT) in setOf("1", "true", "yes")

        private fun nonEmpty(value: String?) = value?.trim()?.takeIf(String::isNotEmpty)

        private companion object {
            const val OTHER = -1
        }
    }
}

internal object PodcastOpmlWriter {
    fun write(feeds: List<PodcastOpmlExportFeed>, createdAtMs: Long): ByteArray {
        val created = DateTimeFormatter.RFC_1123_DATE_TIME.format(ZonedDateTime.ofInstant(Instant.ofEpochMilli(createdAtMs), ZoneOffset.UTC))
        val lines = mutableListOf(
            """<?xml version="1.0" encoding="UTF-8"?>""",
            """<opml version="2.0">""",
            "  <head>",
            "    <title>Enve Podcast Subscriptions</title>",
            "    <dateCreated>${escapeAttribute(created)}</dateCreated>",
            "  </head>",
            "  <body>",
        )
        for (feed in feeds) {
            val attributes = element(listOf("type" to "rss", "text" to feed.title, "title" to feed.title, "xmlUrl" to feed.feedUrl))
            if (feed.episodes.isEmpty()) {
                lines += "    <outline $attributes/>"
                continue
            }
            lines += "    <outline $attributes>"
            for (episode in feed.episodes) {
                val pairs = mutableListOf("type" to "podcast-episode")
                episode.title?.let { pairs += "title" to it }
                episode.guid?.let { pairs += "guid" to it }
                episode.enclosureUrl?.let { pairs += "enclosureUrl" to it }
                episode.publishedAtMs?.let { pairs += "pubDate" to Instant.ofEpochMilli(it).toString() }
                val position = episode.positionSec
                if (episode.isPlayed) {
                    pairs += "played" to "1"
                } else if (position != null && position > 0L) {
                    pairs += "progress" to position.toString()
                }
                episode.updatedAtMs?.let { pairs += "userUpdatedDate" to Instant.ofEpochMilli(it).toString() }
                lines += "      <outline ${element(pairs)}/>"
            }
            lines += "    </outline>"
        }
        lines += listOf("  </body>", "</opml>", "")
        return lines.joinToString("\n").toByteArray(Charsets.UTF_8)
    }

    fun escapeAttribute(value: String): String = buildString(value.length) {
        var index = 0
        while (index < value.length) {
            val codePoint = value.codePointAt(index)
            when (codePoint) {
                '&'.code -> append("&amp;")
                '<'.code -> append("&lt;")
                '>'.code -> append("&gt;")
                '"'.code -> append("&quot;")
                '\''.code -> append("&apos;")
                '\n'.code -> append("&#10;")
                '\r'.code -> append("&#13;")
                '\t'.code -> append("&#9;")
                else -> if (codePoint >= 0x20 && codePoint != 0xFFFE && codePoint != 0xFFFF && codePoint !in 0xD800..0xDFFF) {
                    appendCodePoint(codePoint)
                }
            }
            index += Character.charCount(codePoint)
        }
    }

    private fun element(pairs: List<Pair<String, String>>) = pairs.joinToString(" ") { (name, value) -> "$name=\"${escapeAttribute(value)}\"" }
}
