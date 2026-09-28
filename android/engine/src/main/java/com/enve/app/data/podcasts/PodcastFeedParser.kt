package com.enve.app.data.podcasts

import com.enve.core.data.model.PodcastFeedEpisode
import org.xml.sax.Attributes
import org.xml.sax.InputSource
import org.xml.sax.helpers.DefaultHandler
import java.io.InputStream
import java.io.StringReader
import java.time.OffsetDateTime
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import javax.xml.parsers.SAXParserFactory

private const val ITUNES_NS = "http://www.itunes.com/dtds/podcast-1.0.dtd"
private const val CONTENT_NS = "http://purl.org/rss/1.0/modules/content/"

internal object PodcastFeedParser {
    private val zonedDateFormats = listOf(
        DateTimeFormatter.RFC_1123_DATE_TIME,
        DateTimeFormatter.ofPattern("EEE, d MMM yyyy HH:mm[:ss] z", Locale.US),
        DateTimeFormatter.ofPattern("d MMM yyyy HH:mm[:ss] z", Locale.US),
        DateTimeFormatter.ofPattern("EEE, d MMM yyyy HH:mm[:ss] Z", Locale.US),
    )

    fun parse(input: InputStream): List<PodcastFeedEpisode> {
        val handler = FeedHandler()
        val factory = SAXParserFactory.newInstance().apply { isNamespaceAware = true }
        factory.newSAXParser().parse(InputSource(input), handler)
        return handler.episodes
    }

    internal fun parseDate(raw: String): Long? {
        val value = raw.trim().replace(Regex("\\s+"), " ")
        if (value.isEmpty()) return null
        zonedDateFormats.firstNotNullOfOrNull { format ->
            runCatching { ZonedDateTime.parse(value, format).toInstant().toEpochMilli() }.getOrNull()
        }?.let { return it }
        return runCatching { OffsetDateTime.parse(value).toInstant().toEpochMilli() }.getOrNull()
    }

    internal fun parseDuration(raw: String): Long {
        val parts = raw.trim().split(':')
        if (parts.size > 3) return 0L
        val values = parts.map { it.trim().toDoubleOrNull() ?: return 0L }
        return values.fold(0.0) { total, part -> total * 60 + part }.toLong()
    }

    private class FeedHandler : DefaultHandler() {
        val episodes = mutableListOf<PodcastFeedEpisode>()
        private val text = StringBuilder()
        private var item: ItemFields? = null

        override fun resolveEntity(publicId: String?, systemId: String?): InputSource = InputSource(StringReader(""))

        override fun startElement(uri: String, localName: String, qName: String, attributes: Attributes) {
            text.setLength(0)
            when {
                uri.isEmpty() && localName == "item" -> item = ItemFields()
                uri.isEmpty() && localName == "enclosure" -> item?.let {
                    it.enclosureUrl = attributes.getValue("url")?.trim()?.takeIf(String::isNotEmpty)
                    it.enclosureType = attributes.getValue("type")?.trim()?.takeIf(String::isNotEmpty)
                }
            }
        }

        override fun characters(ch: CharArray, start: Int, length: Int) {
            if (item != null) text.appendRange(ch, start, start + length)
        }

        override fun endElement(uri: String, localName: String, qName: String) {
            val fields = item ?: return
            val value = text.toString().trim()
            text.setLength(0)
            when (uri) {
                "" -> when (localName) {
                    "title" -> fields.title = value
                    "guid" -> fields.guid = value.takeIf(String::isNotEmpty)
                    "pubDate" -> fields.publishedAtMs = parseDate(value)
                    "description" -> fields.description = value.takeIf(String::isNotEmpty)
                    "item" -> {
                        fields.toEpisode()?.let(episodes::add)
                        item = null
                    }
                }
                ITUNES_NS -> when (localName) {
                    "duration" -> fields.durationSec = parseDuration(value)
                    "summary" -> fields.summary = value.takeIf(String::isNotEmpty)
                }
                CONTENT_NS -> if (localName == "encoded") fields.encodedContent = value.takeIf(String::isNotEmpty)
            }
        }
    }

    private class ItemFields {
        var title = ""
        var guid: String? = null
        var publishedAtMs: Long? = null
        var durationSec = 0L
        var description: String? = null
        var encodedContent: String? = null
        var summary: String? = null
        var enclosureUrl: String? = null
        var enclosureType: String? = null

        fun toEpisode(): PodcastFeedEpisode? {
            val url = enclosureUrl ?: return null
            if (title.isEmpty()) return null
            return PodcastFeedEpisode(
                guid = guid ?: url,
                title = title,
                description = description ?: encodedContent ?: summary,
                publishedAtMs = publishedAtMs,
                durationSec = durationSec,
                enclosureUrl = url,
                enclosureType = enclosureType,
            )
        }
    }
}
