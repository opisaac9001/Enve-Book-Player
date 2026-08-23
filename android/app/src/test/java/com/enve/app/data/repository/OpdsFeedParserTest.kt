package com.enve.app.data.repository

import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.BookSource
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsFeedParserTest {

    private val baseUrl = "https://opds.example.com/catalog"
    private val connectionId = "conn-1"

    @Test
    fun parses_acquisition_entry_into_BookSummary() {
        val xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>The Way of Kings</title>
                <id>urn:isbn:9780765326355</id>
                <author><name>Brandon Sanderson</name></author>
                <published>2010-08-31T00:00:00Z</published>
                <link rel="http://opds-spec.org/acquisition"
                      type="application/epub+zip"
                      href="/books/1/download.epub"/>
              </entry>
            </feed>
        """.trimIndent()

        val parsed = OpdsFeedParser.parse(xml, baseUrl, connectionId)

        assertEquals(1, parsed.items.size)
        val book = parsed.items.first()
        assertEquals("The Way of Kings", book.title)
        assertEquals(listOf("Brandon Sanderson"), book.authors)
        assertEquals(BookSource.OPDS, book.source)
        assertEquals(connectionId, book.connectionId)
        assertEquals("EPUB", book.primaryFileType)
        assertEquals(AppMediaType.EBOOK, book.mediaType)
        assertEquals("https://opds.example.com/books/1/download.epub", book.id)
    }

    @Test
    fun collects_navigation_entries_without_rendering_them_as_books() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Fiction</title>
                <id>tag:opds:fiction</id>
                <link rel="subsection" type="application/atom+xml" href="/cat/fiction"/>
              </entry>
              <entry>
                <title>Real Book</title>
                <id>real-1</id>
                <link rel="http://opds-spec.org/acquisition" type="application/pdf" href="/r1.pdf"/>
              </entry>
            </feed>
        """.trimIndent()

        val parsed = OpdsFeedParser.parse(xml, baseUrl, connectionId)
        assertEquals(1, parsed.items.size)
        assertEquals("Real Book", parsed.items.first().title)
        assertEquals(1, parsed.navigationLinks.size)
        assertEquals("Fiction", parsed.navigationLinks.first().title)
        assertEquals("https://opds.example.com/cat/fiction", parsed.navigationLinks.first().href)
    }

    @Test
    fun parses_navigation_root_like_bookorbit() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <title>bookorbit OPDS Catalog</title>
              <entry>
                <title>All Books</title>
                <id>urn:bookorbit:all</id>
                <link rel="subsection" href="/api/v1/opds/catalog" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
              </entry>
            </feed>
        """.trimIndent()

        val parsed = OpdsFeedParser.parse(xml, "https://bibliotheek.example/api/v1/opds", connectionId)

        assertEquals(emptyList<BookSource>(), parsed.items.map { it.source })
        assertEquals(1, parsed.navigationLinks.size)
        assertEquals("All Books", parsed.navigationLinks.first().title)
        assertEquals("https://bibliotheek.example/api/v1/opds/catalog", parsed.navigationLinks.first().href)
    }

    @Test
    fun extracts_thumbnail_in_preference_to_full_cover() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Cover Test</title>
                <id>c1</id>
                <link rel="http://opds-spec.org/image" href="/covers/full.jpg" type="image/jpeg"/>
                <link rel="http://opds-spec.org/image/thumbnail" href="/covers/thumb.jpg" type="image/jpeg"/>
                <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/c1.epub"/>
              </entry>
            </feed>
        """.trimIndent()

        val parsed = OpdsFeedParser.parse(xml, baseUrl, connectionId)
        assertEquals("https://opds.example.com/covers/thumb.jpg", parsed.items.first().thumbnailUrl)
    }

    @Test
    fun follows_link_rel_next_for_pagination() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <link rel="self" href="/catalog?page=1"/>
              <link rel="next" href="/catalog?page=2"/>
              <entry>
                <title>Book</title>
                <id>b1</id>
                <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/b1.epub"/>
              </entry>
            </feed>
        """.trimIndent()

        val parsed = OpdsFeedParser.parse(xml, baseUrl, connectionId)
        assertEquals("https://opds.example.com/catalog?page=2", parsed.nextUrl)
    }

    @Test
    fun returns_null_nextUrl_on_terminal_feed() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <link rel="self" href="/catalog"/>
              <entry>
                <title>Only Book</title>
                <id>only</id>
                <link rel="http://opds-spec.org/acquisition" type="application/pdf" href="/o.pdf"/>
              </entry>
            </feed>
        """.trimIndent()

        val parsed = OpdsFeedParser.parse(xml, baseUrl, connectionId)
        assertNull(parsed.nextUrl)
    }

    @Test
    fun resolves_absolute_href_unchanged() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Absolute</title>
                <id>a1</id>
                <link rel="http://opds-spec.org/acquisition" type="application/epub+zip"
                      href="https://cdn.other.com/book.epub"/>
              </entry>
            </feed>
        """.trimIndent()

        val parsed = OpdsFeedParser.parse(xml, baseUrl, connectionId)
        assertEquals("https://cdn.other.com/book.epub", parsed.items.first().id)
    }

    @Test
    fun decodes_xml_entities_in_title_and_author() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Tom &amp; Jerry &quot;Special&quot;</title>
                <id>tj</id>
                <author><name>O&apos;Brien &lt;jr&gt;</name></author>
                <link rel="http://opds-spec.org/acquisition" type="application/pdf" href="/tj.pdf"/>
              </entry>
            </feed>
        """.trimIndent()

        val parsed = OpdsFeedParser.parse(xml, baseUrl, connectionId)
        val book = parsed.items.first()
        assertEquals("Tom & Jerry \"Special\"", book.title)
        assertEquals(listOf("O'Brien <jr>"), book.authors)
    }

    @Test
    fun infers_audiobook_media_type_from_audio_mime() {
        assertEquals(AppMediaType.AUDIOBOOK, OpdsFeedParser.inferMediaType("audio/mpeg", "/x.mp3"))
        assertEquals(AppMediaType.AUDIOBOOK, OpdsFeedParser.inferMediaType("application/audiobook+zip", "/x.zip"))
    }

    @Test
    fun infers_audiobook_media_type_from_extension_when_mime_is_generic() {
        assertEquals(AppMediaType.AUDIOBOOK, OpdsFeedParser.inferMediaType("application/octet-stream", "/foo/bar.m4b"))
        assertEquals(AppMediaType.EBOOK, OpdsFeedParser.inferMediaType("application/octet-stream", "/foo/bar.epub"))
    }

    @Test
    fun infers_audiobook_media_type_from_opds_link_title_hint() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Generic M4B</title>
                <id>m4b</id>
                <link rel="http://opds-spec.org/acquisition" type="application/octet-stream" title="M4B" href="/download?fileId=1"/>
              </entry>
            </feed>
        """.trimIndent()

        val book = OpdsFeedParser.parse(xml, baseUrl, connectionId).items.first()

        assertEquals(AppMediaType.AUDIOBOOK, book.mediaType)
        assertEquals("M4B", book.primaryFileType)
        assertTrue(book.hasAudio)
    }

    @Test
    fun infers_audiobook_media_type_from_opds2_link_title_hint() {
        val json = """
            {
              "metadata": { "title": "Catalog" },
              "publications": [
                {
                  "metadata": { "title": "Generic MP3" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/download?id=2", "type": "application/octet-stream", "title": "MP3" }
                  ]
                }
              ]
            }
        """.trimIndent()

        val book = OpdsFeedParser.parse(json, baseUrl, connectionId).items.first()

        assertEquals(AppMediaType.AUDIOBOOK, book.mediaType)
        assertEquals("MP3", book.primaryFileType)
        assertTrue(book.hasAudio)
    }

    @Test
    fun infers_file_type_from_mime_then_extension() {
        assertEquals("EPUB", OpdsFeedParser.inferFileType("application/epub+zip", null))
        assertEquals("PDF", OpdsFeedParser.inferFileType("application/pdf", null))
        assertEquals("CBZ", OpdsFeedParser.inferFileType("application/x-cbz", null))
        assertEquals("CBR", OpdsFeedParser.inferFileType("application/x-cbr", null))
        assertEquals("EPUB", OpdsFeedParser.inferFileType("", "/path/to/book.epub"))
        assertEquals("AUDIOBOOK", OpdsFeedParser.inferFileType("", "/path/to/book.m4b"))
        assertNull(OpdsFeedParser.inferFileType("", "/path/to/book.unknown"))
    }

    @Test
    fun isAcquisition_recognizes_common_link_shapes() {
        assertTrue(OpdsFeedParser.isAcquisition("""<link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="x"/>"""))
        assertTrue(OpdsFeedParser.isAcquisition("""<link rel="http://opds-spec.org/acquisition/open-access" type="application/pdf" href="x"/>"""))
        assertTrue(OpdsFeedParser.isAcquisition("""<link type="application/epub+zip" href="x"/>"""))
        assertTrue(OpdsFeedParser.isAcquisition("""<link type="audio/mpeg" href="x"/>"""))
        assertFalse(OpdsFeedParser.isAcquisition("""<link rel="subsection" type="application/atom+xml" href="x"/>"""))
        assertFalse(OpdsFeedParser.isAcquisition("""<link rel="self" href="x"/>"""))
    }

    @Test
    fun resolve_handles_relative_and_absolute_hrefs() {
        assertEquals(
            "https://opds.example.com/x.epub",
            OpdsFeedParser.resolve(baseUrl, "/x.epub"),
        )
        assertEquals(
            "https://opds.example.com/catalog/x.epub",
            OpdsFeedParser.resolve("$baseUrl/", "x.epub"),
        )
        assertEquals(
            "https://cdn.other.com/x.epub",
            OpdsFeedParser.resolve(baseUrl, "https://cdn.other.com/x.epub"),
        )
    }

    @Test
    fun parseInstant_returns_zero_for_malformed_input() {
        assertEquals(0L, OpdsFeedParser.parseInstant(null))
        assertEquals(0L, OpdsFeedParser.parseInstant(""))
        assertEquals(0L, OpdsFeedParser.parseInstant("not a date"))
    }

    @Test
    fun parseInstant_parses_ISO8601_offset_datetime() {
        val ms = OpdsFeedParser.parseInstant("2010-08-31T00:00:00Z")
        assertEquals(1283212800000L, ms)
    }

    @Test
    fun parses_opds2_publications() {
        val json = """
            {
              "metadata": { "title": "Catalog", "numberOfItems": 1 },
              "publications": [
                {
                  "metadata": {
                    "title": "OPDS 2 Book",
                    "author": [{ "name": "Ada Lovelace" }],
                    "published": "2020-01-02T00:00:00Z"
                  },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/books/opds2.epub", "type": "application/epub+zip" }
                  ],
                  "images": [
                    { "rel": "thumbnail", "href": "/covers/opds2.jpg", "type": "image/jpeg" }
                  ]
                }
              ],
              "links": [
                { "rel": "next", "href": "/catalog?page=2", "type": "application/opds+json" }
              ]
            }
        """.trimIndent()

        val parsed = OpdsFeedParser.parse(json, baseUrl, connectionId)
        val book = parsed.items.first()

        assertEquals("OPDS 2 Book", book.title)
        assertEquals(listOf("Ada Lovelace"), book.authors)
        assertEquals("https://opds.example.com/books/opds2.epub", book.id)
        assertEquals("https://opds.example.com/covers/opds2.jpg", book.thumbnailUrl)
        assertEquals("https://opds.example.com/catalog?page=2", parsed.nextUrl)
        assertEquals(1, parsed.totalResults)
    }

    @Test
    fun multi_entry_feed_preserves_order() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>First</title><id>1</id>
                <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/1.epub"/>
              </entry>
              <entry>
                <title>Second</title><id>2</id>
                <link rel="http://opds-spec.org/acquisition" type="application/pdf" href="/2.pdf"/>
              </entry>
              <entry>
                <title>Third</title><id>3</id>
                <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/3.epub"/>
              </entry>
            </feed>
        """.trimIndent()

        val titles = OpdsFeedParser.parse(xml, baseUrl, connectionId).items.map { it.title }
        assertEquals(listOf("First", "Second", "Third"), titles)
    }

    @Test
    fun multiple_authors_are_each_extracted() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Co-authored</title><id>co</id>
                <author><name>Brandon Sanderson</name></author>
                <author><name>Janci Patterson</name></author>
                <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/co.epub"/>
              </entry>
            </feed>
        """.trimIndent()

        val authors = OpdsFeedParser.parse(xml, baseUrl, connectionId).items.first().authors
        assertEquals(listOf("Brandon Sanderson", "Janci Patterson"), authors)
    }

    @Test
    fun falls_back_to_updated_when_published_is_missing() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Fallback</title><id>f1</id>
                <updated>2010-08-31T00:00:00Z</updated>
                <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/f1.epub"/>
              </entry>
            </feed>
        """.trimIndent()

        val book = OpdsFeedParser.parse(xml, baseUrl, connectionId).items.first()
        assertEquals(1283212800000L, book.addedOn)
    }
}
