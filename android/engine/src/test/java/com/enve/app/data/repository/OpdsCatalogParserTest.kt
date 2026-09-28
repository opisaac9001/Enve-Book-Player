package com.enve.app.data.repository

import com.enve.core.data.model.AppMediaType
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Locale

class OpdsCatalogParserTest {

    private val baseUrl = "https://opds.example.com/v2/catalog"
    private val connectionId = "conn-opds2"

    private fun parse(document: String) = OpdsFeedParser.parse(document, baseUrl, connectionId)

    @Test
    fun reads_feed_metadata_pagination_and_search_without_crawling_them() {
        val feed = """
            {
              "metadata": { "title": "Example Catalog", "numberOfItems": 5432, "itemsPerPage": 50, "currentPage": 2 },
              "links": [
                { "rel": "self", "href": "/v2/catalog?page=2", "type": "application/opds+json" },
                { "rel": ["next"], "href": "/v2/catalog?page=3", "type": "application/opds+json" },
                { "rel": "previous", "href": "/v2/catalog?page=1", "type": "application/opds+json" },
                { "rel": "first", "href": "/v2/catalog?page=1", "type": "application/opds+json" },
                { "rel": "last", "href": "/v2/catalog?page=109", "type": "application/opds+json" },
                { "rel": "search", "href": "/search{?query}", "type": "application/opds+json", "templated": true }
              ],
              "navigation": [
                { "href": "/new", "title": "New Publications", "type": "application/opds+json", "rel": "current" }
              ]
            }
        """.trimIndent()

        val parsed = parse(feed)

        assertEquals("Example Catalog", parsed.title)
        assertEquals(5432, parsed.totalResults)
        assertEquals(50, parsed.itemsPerPage)
        assertEquals(2, parsed.currentPage)
        assertEquals("https://opds.example.com/v2/catalog?page=3", parsed.nextUrl)
        assertEquals("https://opds.example.com/v2/catalog?page=1", parsed.previousUrl)
        assertEquals("https://opds.example.com/v2/catalog?page=1", parsed.firstUrl)
        assertEquals("https://opds.example.com/v2/catalog?page=109", parsed.lastUrl)
        assertEquals("https://opds.example.com/v2/catalog?page=2", parsed.selfUrl)
        assertEquals(1, parsed.navigationLinks.size)
        assertEquals("New Publications", parsed.navigationLinks.first().title)
        assertEquals(1, parsed.searchLinks.size)
        assertEquals("https://opds.example.com/search{?query}", parsed.searchLinks.first().href)
        assertTrue(parsed.searchLinks.first().templated)
        assertTrue(parsed.items.isEmpty())
    }

    @Test
    fun reads_groups_including_nested_navigation_and_publications() {
        val feed = """
            {
              "metadata": { "title": "Home" },
              "links": [ { "rel": "self", "href": "/home", "type": "application/opds+json" } ],
              "groups": [
                {
                  "metadata": { "title": "Recently Added" },
                  "links": [ { "rel": "self", "href": "/recent", "type": "application/opds+json" } ],
                  "publications": [
                    {
                      "metadata": { "title": "Grouped Book", "identifier": "urn:uuid:group-1" },
                      "links": [
                        { "rel": "http://opds-spec.org/acquisition/open-access", "href": "/g1.epub", "type": "application/epub+zip" }
                      ]
                    }
                  ]
                },
                {
                  "metadata": { "title": "Browse" },
                  "navigation": [
                    { "href": "/browse/fiction", "title": "Fiction", "type": "application/opds+json" }
                  ]
                }
              ]
            }
        """.trimIndent()

        val parsed = parse(feed)

        assertEquals(2, parsed.groups.size)
        assertEquals("Recently Added", parsed.groups[0].title)
        assertEquals("https://opds.example.com/recent", parsed.groups[0].selfUrl)
        assertEquals(1, parsed.groups[0].publications.size)
        assertEquals(1, parsed.groups[1].navigationLinks.size)
        assertEquals("Fiction", parsed.groups[1].navigationLinks.first().title)
        assertEquals(listOf("Grouped Book"), parsed.items.map { it.title })
        assertEquals(
            listOf("https://opds.example.com/browse/fiction"),
            parsed.allNavigationLinks.map { it.href },
        )
    }

    @Test
    fun top_level_catalogs_become_navigation_not_books() {
        val feed = """
            {
              "metadata": { "title": "Catalog Feed" },
              "catalogs": [
                {
                  "metadata": { "title": "Feedbooks", "numberOfItems": 12 },
                  "links": [
                    { "rel": "http://opds-spec.org/catalog", "href": "/feedbooks", "type": "application/opds+json" }
                  ],
                  "images": [ { "href": "/fb.png", "type": "image/png" } ]
                }
              ]
            }
        """.trimIndent()

        val parsed = parse(feed)

        assertTrue(parsed.items.isEmpty())
        assertTrue(parsed.publications.isEmpty())
        assertEquals(1, parsed.navigationLinks.size)
        val navigation = parsed.navigationLinks.first()
        assertEquals("Feedbooks", navigation.title)
        assertEquals("https://opds.example.com/feedbooks", navigation.href)
        assertEquals(12, navigation.numberOfItems)
    }

    @Test
    fun acquisition_rel_aliases_and_historical_uris_are_recognized() {
        assertEquals(OpdsAcquisitionKind.GENERIC, OpdsFeedParser.acquisitionKind(listOf("http://opds-spec.org/acquisition")))
        assertEquals(OpdsAcquisitionKind.OPEN_ACCESS, OpdsFeedParser.acquisitionKind(listOf("http://opds-spec.org/acquisition/open-access")))
        assertEquals(OpdsAcquisitionKind.BORROW, OpdsFeedParser.acquisitionKind(listOf("http://opds-spec.org/acquisition/borrow")))
        assertEquals(OpdsAcquisitionKind.BUY, OpdsFeedParser.acquisitionKind(listOf("http://opds-spec.org/acquisition/buy")))
        assertEquals(OpdsAcquisitionKind.PREVIEW, OpdsFeedParser.acquisitionKind(listOf("http://opds-spec.org/acquisition/sample")))
        assertEquals(OpdsAcquisitionKind.PREVIEW, OpdsFeedParser.acquisitionKind(listOf("http://opds-spec.org/acquisition/preview")))
        assertEquals(OpdsAcquisitionKind.SUBSCRIBE, OpdsFeedParser.acquisitionKind(listOf("http://opds-spec.org/acquisition/subscribe")))

        assertEquals(OpdsAcquisitionKind.BUY, OpdsFeedParser.acquisitionKind(listOf("http://opds-spec.org/buy")))
        assertEquals(OpdsAcquisitionKind.BORROW, OpdsFeedParser.acquisitionKind(listOf("http://opds-spec.org/borrow")))
        assertEquals(OpdsAcquisitionKind.SUBSCRIBE, OpdsFeedParser.acquisitionKind(listOf("http://opds-spec.org/subscribe")))
        assertEquals(OpdsAcquisitionKind.PREVIEW, OpdsFeedParser.acquisitionKind(listOf("http://opds-spec.org/sample")))
        assertEquals(OpdsAcquisitionKind.GENERIC, OpdsFeedParser.acquisitionKind(listOf("download")))

        assertEquals(
            OpdsAcquisitionKind.BORROW,
            OpdsFeedParser.acquisitionKind(listOf("http://opds-spec.org/acquisition", "http://opds-spec.org/acquisition/borrow")),
        )
        assertNull(OpdsFeedParser.acquisitionKind(listOf("self", "alternate", "http://opds-spec.org/image")))
    }

    @Test
    fun selects_the_open_access_link_over_transactional_and_sample_links() {
        val feed = """
            {
              "publications": [
                {
                  "metadata": { "title": "Multi", "identifier": "urn:multi" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition/buy", "href": "/buy.epub", "type": "application/epub+zip",
                      "properties": { "price": { "currency": "USD", "value": 0 } } },
                    { "rel": "http://opds-spec.org/acquisition", "href": "/generic.pdf", "type": "application/pdf" },
                    { "rel": "http://opds-spec.org/acquisition/open-access", "href": "/open.epub", "type": "application/epub+zip" },
                    { "rel": "http://opds-spec.org/acquisition/sample", "href": "/sample.epub", "type": "application/epub+zip" }
                  ]
                }
              ]
            }
        """.trimIndent()

        val publication = parse(feed).publications.single()

        assertEquals(4, publication.acquisitions.size)
        assertEquals(OpdsAcquisitionKind.OPEN_ACCESS, publication.selectedAcquisition?.kind)
        assertEquals("https://opds.example.com/open.epub", publication.downloadUrl)
        assertEquals("https://opds.example.com/open.epub", publication.summary.opdsAcquisitionUrl)
        assertTrue(publication.isDownloadable)
        assertEquals("urn:multi", publication.id)

        val buy = publication.acquisitions.single { it.kind == OpdsAcquisitionKind.BUY }
        assertEquals(0.0, buy.price?.value ?: -1.0, 0.0001)
        assertEquals("USD", buy.price?.currency)
    }

    @Test
    fun transactional_only_publication_stays_listable_without_a_download_url() {
        val feed = """
            {
              "publications": [
                {
                  "metadata": { "title": "Buy Only", "identifier": "urn:buy" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition/buy", "href": "/buy.epub", "type": "application/epub+zip",
                      "properties": {
                        "price": { "currency": "EUR", "value": 9.99 },
                        "availability": { "state": "available", "until": "2026-12-01T00:00:00Z" },
                        "copies": { "total": 10, "available": 0 },
                        "holds": { "total": 0, "position": 0 }
                      } }
                  ]
                }
              ]
            }
        """.trimIndent()

        val parsed = parse(feed)
        val publication = parsed.publications.single()
        val acquisition = publication.selectedAcquisition!!

        assertEquals(listOf("Buy Only"), parsed.items.map { it.title })
        assertNull(parsed.items.single().opdsAcquisitionUrl)
        assertFalse(publication.isDownloadable)
        assertNull(publication.downloadUrl)
        assertTrue(acquisition.isTransactional)
        assertEquals(9.99, acquisition.price?.value ?: -1.0, 0.0001)
        assertEquals("available", acquisition.availability?.state)
        assertEquals("2026-12-01T00:00:00Z", acquisition.availability?.until)
        assertEquals(10, acquisition.copies?.total)
        assertEquals(0, acquisition.copies?.available)
        assertEquals(0, acquisition.holds?.total)
        assertEquals(0, acquisition.holds?.position)
    }

    @Test
    fun lcp_and_adept_publications_stay_listable_but_never_yield_a_download_url() {
        val feed = """
            {
              "publications": [
                {
                  "metadata": { "title": "LCP Book", "identifier": "urn:lcp" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/lcp", "type": "application/vnd.readium.lcp.license.v1.0+json",
                      "properties": { "indirectAcquisition": [ { "type": "application/epub+zip" } ] } }
                  ]
                },
                {
                  "metadata": { "title": "Adept Book", "identifier": "urn:adept" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/adept", "type": "application/atom+xml;type=entry;profile=opds-catalog",
                      "properties": {
                        "indirectAcquisition": [
                          { "type": "application/vnd.adobe.adept+xml", "child": [ { "type": "application/epub+zip" } ] }
                        ]
                      } }
                  ]
                }
              ]
            }
        """.trimIndent()

        val parsed = parse(feed)
        assertEquals(listOf("LCP Book", "Adept Book"), parsed.items.map { it.title })
        assertTrue(parsed.items.all { it.opdsAcquisitionUrl == null })
        assertEquals(2, parsed.publications.size)

        val lcp = parsed.publications.single { it.id == "urn:lcp" }.selectedAcquisition!!
        assertEquals(OpdsDrm.LCP, lcp.drm)
        assertEquals(OpdsFormat.EPUB, lcp.format)
        assertFalse(lcp.isSupported)
        assertFalse(lcp.isDirectlyDownloadable)

        val adept = parsed.publications.single { it.id == "urn:adept" }.selectedAcquisition!!
        assertEquals(OpdsDrm.ADEPT, adept.drm)
        assertTrue(adept.requiresIndirectFetch)
        assertEquals("application/vnd.adobe.adept+xml", adept.indirect.single().type)
        assertEquals("application/epub+zip", adept.indirect.single().children.single().type)
    }

    @Test
    fun keeps_the_stable_identifier_instead_of_the_expiring_acquisition_url() {
        val feed = """
            {
              "publications": [
                {
                  "metadata": { "title": "Signed", "identifier": "urn:uuid:stable-1" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/download?token=expires-soon", "type": "application/epub+zip" },
                    { "rel": "self", "href": "/publication/1", "type": "application/opds-publication+json" }
                  ]
                },
                {
                  "metadata": { "title": "No Identifier" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/plain.epub", "type": "application/epub+zip" }
                  ]
                }
              ]
            }
        """.trimIndent()

        val parsed = parse(feed)

        val stable = parsed.publications.single { it.identifier == "urn:uuid:stable-1" }
        assertEquals("urn:uuid:stable-1", stable.id)
        assertEquals("https://opds.example.com/download?token=expires-soon", stable.downloadUrl)
        assertEquals("https://opds.example.com/download?token=expires-soon", stable.summary.opdsAcquisitionUrl)
        assertEquals("https://opds.example.com/publication/1", stable.selfUrl)

        val fallback = parsed.publications.single { it.identifier == null }
        assertEquals("https://opds.example.com/plain.epub", fallback.id)
    }

    @Test
    fun reads_publication_metadata_and_series() {
        val feed = """
            {
              "publications": [
                {
                  "metadata": {
                    "title": "Metadata Rich",
                    "identifier": "urn:meta",
                    "author": [ { "name": "Ada Lovelace" }, "Charles Babbage" ],
                    "narrator": { "name": "Grace Hopper" },
                    "publisher": { "name": "Analytical Press" },
                    "language": [ "en", "fr" ],
                    "subject": [ { "name": "Science" }, "History" ],
                    "numberOfPages": 321,
                    "published": "2020-01-02T00:00:00Z",
                    "belongsTo": { "series": [ { "name": "Engines", "position": 2 } ] }
                  },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/m.epub", "type": "application/epub+zip" }
                  ],
                  "images": [
                    { "href": "/big.jpg", "type": "image/jpeg", "width": 1400 },
                    { "href": "/small.jpg", "type": "image/jpeg", "width": 200 }
                  ]
                }
              ]
            }
        """.trimIndent()

        val book = parse(feed).items.single()

        assertEquals(listOf("Ada Lovelace", "Charles Babbage"), book.authors)
        assertEquals("Grace Hopper", book.narrator)
        assertEquals("Analytical Press", book.publisher)
        assertEquals("en", book.language)
        assertEquals(listOf("Science", "History"), book.categories)
        assertEquals(321, book.pageCount)
        assertEquals("Engines", book.seriesName)
        assertEquals("2", book.seriesNumber)
        assertEquals("https://opds.example.com/small.jpg", book.thumbnailUrl)
        assertEquals(AppMediaType.EBOOK, book.mediaType)
    }

    @Test
    fun recognizes_every_supported_and_unsupported_format() {
        assertEquals(OpdsFormat.EPUB, OpdsFeedParser.formatFor("application/epub+zip"))
        assertEquals(OpdsFormat.PDF, OpdsFeedParser.formatFor("application/pdf"))
        assertEquals(OpdsFormat.CBZ, OpdsFeedParser.formatFor("application/vnd.comicbook+zip"))
        assertEquals(OpdsFormat.CBR, OpdsFeedParser.formatFor("application/vnd.comicbook-rar"))
        assertEquals(OpdsFormat.MOBI, OpdsFeedParser.formatFor("application/x-mobipocket-ebook"))
        assertEquals(OpdsFormat.AZW3, OpdsFeedParser.formatFor("application/vnd.amazon.mobi8-ebook"))
        assertEquals(OpdsFormat.AUDIO, OpdsFeedParser.formatFor("audio/mpeg"))
        assertEquals(OpdsFormat.AUDIOBOOK_PACKAGE, OpdsFeedParser.formatFor("application/audiobook+json"))
        assertEquals(OpdsFormat.WEBPUB, OpdsFeedParser.formatFor("application/webpub+json"))
        assertEquals(OpdsFormat.DIVINA, OpdsFeedParser.formatFor("application/divina+json"))
        assertEquals(OpdsFormat.OPDS_PUBLICATION, OpdsFeedParser.formatFor("application/opds-publication+json"))
        assertEquals(OpdsFormat.OPDS_FEED, OpdsFeedParser.formatFor("application/atom+xml;type=entry;profile=opds-catalog"))
        assertEquals(OpdsFormat.UNKNOWN, OpdsFeedParser.formatFor("application/octet-stream"))

        listOf(OpdsFormat.EPUB, OpdsFormat.PDF, OpdsFormat.CBZ, OpdsFormat.CBR, OpdsFormat.MOBI, OpdsFormat.AZW3, OpdsFormat.AUDIO)
            .forEach { assertTrue(it.name, it.isReadableContent) }
        listOf(OpdsFormat.AUDIOBOOK_PACKAGE, OpdsFormat.WEBPUB, OpdsFormat.DIVINA, OpdsFormat.OPDS_FEED, OpdsFormat.UNKNOWN)
            .forEach { assertFalse(it.name, it.isReadableContent) }
    }

    @Test
    fun audiobook_and_comic_publications_map_to_the_right_media_type() {
        val feed = """
            {
              "publications": [
                {
                  "metadata": { "title": "Narrated", "identifier": "urn:audio" },
                  "links": [ { "rel": "http://opds-spec.org/acquisition", "href": "/a.m4b", "type": "audio/mp4" } ]
                },
                {
                  "metadata": { "title": "Comic", "identifier": "urn:comic" },
                  "links": [ { "rel": "http://opds-spec.org/acquisition", "href": "/c.cbz", "type": "application/vnd.comicbook+zip" } ]
                },
                {
                  "metadata": { "title": "Packaged Audiobook", "identifier": "urn:lpf" },
                  "links": [ { "rel": "http://opds-spec.org/acquisition", "href": "/a.lpf", "type": "application/audiobook+zip" } ]
                }
              ]
            }
        """.trimIndent()

        val parsed = parse(feed)

        val audio = parsed.publications.single { it.id == "urn:audio" }
        assertEquals(AppMediaType.AUDIOBOOK, audio.summary.mediaType)
        assertTrue(audio.summary.hasAudio)
        assertTrue(audio.isDownloadable)

        val comic = parsed.publications.single { it.id == "urn:comic" }
        assertEquals("CBZ", comic.summary.primaryFileType)
        assertTrue(comic.isDownloadable)

        val packaged = parsed.publications.single { it.id == "urn:lpf" }
        assertEquals(OpdsFormat.AUDIOBOOK_PACKAGE, packaged.selectedAcquisition?.format)
        assertFalse(packaged.isDownloadable)
        assertNull(parsed.items.single { it.id == "urn:lpf" }.opdsAcquisitionUrl)
    }

    @Test
    fun resolves_relative_protocol_relative_and_templated_hrefs() {
        assertEquals(
            "https://opds.example.com/v2/books/1.epub",
            OpdsFeedParser.resolve(baseUrl, "books/1.epub"),
        )
        assertEquals(
            "https://opds.example.com/abs/2.epub",
            OpdsFeedParser.resolve(baseUrl, "/abs/2.epub"),
        )
        assertEquals(
            "https://cdn.example.org/3.epub",
            OpdsFeedParser.resolve(baseUrl, "//cdn.example.org/3.epub"),
        )
        assertEquals(
            "https://opds.example.com/search{?query}",
            OpdsFeedParser.resolve(baseUrl, "/search{?query}"),
        )
        assertEquals(
            "https://cdn.other.com/4.epub",
            OpdsFeedParser.resolve(baseUrl, "https://cdn.other.com/4.epub"),
        )
    }

    @Test
    fun only_feed_shaped_navigation_types_are_traversable() {
        assertTrue(OpdsFeedParser.isTraversableFeedType(""))
        assertTrue(OpdsFeedParser.isTraversableFeedType("application/opds+json"))
        assertTrue(OpdsFeedParser.isTraversableFeedType("application/atom+xml;profile=opds-catalog;kind=navigation"))
        assertFalse(OpdsFeedParser.isTraversableFeedType("application/opds-publication+json"))
        assertFalse(OpdsFeedParser.isTraversableFeedType("text/html"))
        assertFalse(OpdsFeedParser.isTraversableFeedType("image/png"))
    }

    @Test
    fun opds1_entry_carries_indirect_acquisition_price_copies_and_holds() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
              <entry>
                <title>Borrowable</title>
                <id>urn:uuid:borrow-1</id>
                <link rel="http://opds-spec.org/acquisition/borrow"
                      href="/borrow/1"
                      type="application/atom+xml;type=entry;profile=opds-catalog">
                  <opds:indirectAcquisition type="application/vnd.adobe.adept+xml">
                    <opds:indirectAcquisition type="application/epub+zip"/>
                  </opds:indirectAcquisition>
                  <opds:availability status="available" since="2026-01-01T00:00:00Z"/>
                  <opds:copies total="10" available="0"/>
                  <opds:holds total="0" position="0"/>
                  <opds:price currencycode="USD">0.00</opds:price>
                </link>
              </entry>
            </feed>
        """.trimIndent()

        val parsed = OpdsFeedParser.parse(xml, baseUrl, connectionId)
        val publication = parsed.publications.single()
        val acquisition = publication.selectedAcquisition!!

        assertEquals(listOf("Borrowable"), parsed.items.map { it.title })
        assertNull(parsed.items.single().opdsAcquisitionUrl)
        assertEquals("urn:uuid:borrow-1", publication.identifier)
        assertEquals(OpdsAcquisitionKind.BORROW, acquisition.kind)
        assertEquals(OpdsDrm.ADEPT, acquisition.drm)
        assertTrue(acquisition.requiresIndirectFetch)
        assertEquals("application/vnd.adobe.adept+xml", acquisition.indirect.single().type)
        assertEquals("application/epub+zip", acquisition.indirect.single().children.single().type)
        assertEquals("available", acquisition.availability?.state)
        assertEquals("2026-01-01T00:00:00Z", acquisition.availability?.since)
        assertEquals(10, acquisition.copies?.total)
        assertEquals(0, acquisition.copies?.available)
        assertEquals(0, acquisition.holds?.total)
        assertEquals(0, acquisition.holds?.position)
        assertEquals(0.0, acquisition.price?.value ?: -1.0, 0.0001)
        assertEquals("USD", acquisition.price?.currency)
    }

    @Test
    fun opds1_feed_retains_facets_and_search_without_treating_them_as_navigation() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom"
                  xmlns:opds="http://opds-spec.org/2010/catalog"
                  xmlns:thr="http://purl.org/syndication/thread/1.0">
              <title>Faceted</title>
              <link rel="search" type="application/opensearchdescription+xml" href="/search.xml"/>
              <link rel="http://opds-spec.org/facet" href="/lang/en" title="English"
                    opds:facetGroup="Language" thr:count="1234" opds:activeFacet="true"/>
              <link rel="http://opds-spec.org/facet" href="/lang/fr" title="French"
                    opds:facetGroup="Language" thr:count="0"/>
              <entry>
                <title>Faceted Book</title>
                <id>fb-1</id>
                <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/fb1.epub"/>
              </entry>
            </feed>
        """.trimIndent()

        val parsed = OpdsFeedParser.parse(xml, baseUrl, connectionId)

        assertEquals("Faceted", parsed.title)
        assertEquals(1, parsed.items.size)
        assertTrue(parsed.navigationLinks.isEmpty())
        assertEquals(2, parsed.facets.size)
        assertEquals("Language", parsed.facets[0].groupTitle)
        assertEquals("English", parsed.facets[0].title)
        assertEquals(1234, parsed.facets[0].numberOfItems)
        assertTrue(parsed.facets[0].isActive)
        assertEquals(0, parsed.facets[1].numberOfItems)
        assertFalse(parsed.facets[1].isActive)
        assertEquals(1, parsed.searchLinks.size)
        assertEquals("https://opds.example.com/search.xml", parsed.searchLinks.single().href)
    }

    @Test
    fun opds1_buy_only_entry_is_listed_without_a_download_url() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>For Sale</title>
                <id>sale-1</id>
                <link rel="http://opds-spec.org/acquisition/buy" type="application/epub+zip" href="/sale.epub"/>
              </entry>
              <entry>
                <title>Free</title>
                <id>free-1</id>
                <link rel="http://opds-spec.org/acquisition/open-access" type="application/epub+zip" href="/free.epub"/>
              </entry>
            </feed>
        """.trimIndent()

        val parsed = OpdsFeedParser.parse(xml, baseUrl, connectionId)

        assertEquals(listOf("For Sale", "Free"), parsed.items.map { it.title })
        assertNull(parsed.items.single { it.title == "For Sale" }.opdsAcquisitionUrl)
        assertEquals("https://opds.example.com/free.epub", parsed.items.single { it.title == "Free" }.opdsAcquisitionUrl)
        assertEquals(2, parsed.publications.size)
        assertNotNull(parsed.publications.single { it.identifier == "sale-1" }.selectedAcquisition)
        assertFalse(parsed.publications.single { it.identifier == "sale-1" }.isDownloadable)
    }

    @Test
    fun opds1_entry_keeps_its_stable_id_and_persists_the_acquisition_url() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Legacy</title>
                <id>urn:isbn:9780765326355</id>
                <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/legacy.epub"/>
              </entry>
            </feed>
        """.trimIndent()

        val parsed = OpdsFeedParser.parse(xml, baseUrl, connectionId)
        val publication = parsed.publications.single()

        assertEquals("urn:isbn:9780765326355", publication.id)
        assertEquals("urn:isbn:9780765326355", publication.summary.id)
        assertEquals("urn:isbn:9780765326355", publication.identifier)
        assertEquals("9780765326355", publication.summary.isbn13)
        assertEquals("https://opds.example.com/legacy.epub", publication.summary.opdsAcquisitionUrl)
    }

    @Test
    fun entry_level_next_link_does_not_leak_into_feed_pagination() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <link rel="self" href="/v2/catalog"/>
              <entry>
                <title>Chaptered</title>
                <id>c-1</id>
                <link rel="next" href="/entry/next"/>
                <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/c1.epub"/>
              </entry>
            </feed>
        """.trimIndent()

        assertNull(OpdsFeedParser.parse(xml, baseUrl, connectionId).nextUrl)
    }

    @Test
    fun decodes_localized_language_maps_for_title_subtitle_and_series() {
        val feed = """
            {
              "metadata": { "title": { "fr": "Catalogue", "en": "Catalog" } },
              "publications": [
                {
                  "metadata": {
                    "title": { "fr": "Le Livre", "en-GB": "The Book", "en": "The Book (US)" },
                    "subtitle": { "fr": "Un sous-titre", "en": "A Subtitle" },
                    "identifier": "urn:localized",
                    "author": [ { "name": { "en": "Ada Lovelace" } } ],
                    "belongsTo": { "series": [ { "name": { "en": "Engines", "fr": "Moteurs" }, "position": 3 } ] }
                  },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/l.epub", "type": "application/epub+zip" }
                  ]
                },
                {
                  "metadata": { "title": { "de": "Nur Deutsch" }, "identifier": "urn:de" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/de.epub", "type": "application/epub+zip" }
                  ]
                }
              ]
            }
        """.trimIndent()

        val previous = Locale.getDefault()
        Locale.setDefault(Locale.forLanguageTag("en-GB"))
        try {
            val parsed = parse(feed)
            val book = parsed.items.single { it.id == "urn:localized" }

            assertEquals("Catalog", parsed.title)
            assertEquals("The Book", book.title)
            assertEquals("A Subtitle", book.subtitle)
            assertEquals("Engines", book.seriesName)
            assertEquals("3", book.seriesNumber)
            assertEquals(listOf("Ada Lovelace"), book.authors)
            assertEquals("Nur Deutsch", parsed.items.single { it.id == "urn:de" }.title)
        } finally {
            Locale.setDefault(previous)
        }
    }

    @Test
    fun a_publication_with_an_unclassifiable_acquisition_is_listed_without_a_download_url() {
        val feed = """
            {
              "publications": [
                {
                  "metadata": { "title": "Mystery Blob", "identifier": "urn:blob" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/blob", "type": "application/octet-stream" }
                  ]
                }
              ]
            }
        """.trimIndent()

        val parsed = parse(feed)
        val publication = parsed.publications.single()

        assertEquals(OpdsFormat.UNKNOWN, publication.selectedAcquisition?.format)
        assertFalse(publication.isDownloadable)
        assertEquals(listOf("Mystery Blob"), parsed.items.map { it.title })
        assertNull(parsed.items.single().opdsAcquisitionUrl)
    }

    @Test
    fun a_publication_offering_both_formats_reports_audio_and_ebook_independently() {
        val feed = """
            {
              "publications": [
                {
                  "metadata": { "title": "Both", "identifier": "urn:both" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/b.epub", "type": "application/epub+zip" },
                    { "rel": "http://opds-spec.org/acquisition", "href": "/b.m4b", "type": "audio/mp4" }
                  ]
                },
                {
                  "metadata": { "title": "Audio Only", "identifier": "urn:audio-only" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/a.mp3", "type": "audio/mpeg" }
                  ]
                }
              ]
            }
        """.trimIndent()

        val parsed = parse(feed)

        val both = parsed.items.single { it.id == "urn:both" }
        assertTrue(both.hasEbook)
        assertTrue(both.hasAudio)
        assertEquals(AppMediaType.EBOOK, both.mediaType)

        val audio = parsed.items.single { it.id == "urn:audio-only" }
        assertTrue(audio.hasAudio)
        assertFalse(audio.hasEbook)
    }

    @Test
    fun non_http_acquisition_and_feed_links_are_rejected() {
        val feed = """
            {
              "metadata": { "title": "Guarded" },
              "links": [ { "rel": "next", "href": "ftp://opds.example.com/page2", "type": "application/opds+json" } ],
              "publications": [
                {
                  "metadata": { "title": "Scripted", "identifier": "urn:scripted" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "javascript:alert(1)", "type": "application/epub+zip" }
                  ]
                }
              ]
            }
        """.trimIndent()

        val parsed = parse(feed)

        assertNull(parsed.nextUrl)
        assertTrue(parsed.publications.single().acquisitions.isEmpty())
        assertNull(parsed.items.single().opdsAcquisitionUrl)
    }

    @Test
    fun repeated_publications_across_groups_are_listed_once_without_dropping_the_others() {
        val feed = """
            {
              "publications": [
                {
                  "metadata": { "title": "Shared", "identifier": "urn:shared" },
                  "links": [ { "rel": "http://opds-spec.org/acquisition", "href": "/s.epub", "type": "application/epub+zip" } ]
                },
                {
                  "metadata": { "title": "Unique", "identifier": "urn:unique" },
                  "links": [ { "rel": "http://opds-spec.org/acquisition", "href": "/u.epub", "type": "application/epub+zip" } ]
                }
              ],
              "groups": [
                {
                  "metadata": { "title": "Featured" },
                  "publications": [
                    {
                      "metadata": { "title": "Shared", "identifier": "urn:shared" },
                      "links": [ { "rel": "http://opds-spec.org/acquisition", "href": "/s.epub", "type": "application/epub+zip" } ]
                    },
                    {
                      "metadata": { "title": "Grouped", "identifier": "urn:grouped" },
                      "links": [ { "rel": "http://opds-spec.org/acquisition", "href": "/g.epub", "type": "application/epub+zip" } ]
                    }
                  ]
                }
              ]
            }
        """.trimIndent()

        val parsed = parse(feed)

        assertEquals(listOf("urn:shared", "urn:unique", "urn:grouped"), parsed.items.map { it.id })
    }

    @Test
    fun parses_bare_dates_alongside_offset_timestamps() {
        assertEquals(1283212800000L, OpdsFeedParser.parseInstant("2010-08-31"))
        assertEquals(1283212800000L, OpdsFeedParser.parseInstant("2010-08-31T00:00:00Z"))
        assertEquals(0L, OpdsFeedParser.parseInstant("31-08-2010"))
    }

    @Test
    fun decodes_named_and_numeric_xml_entities() {
        val xml = """
            <feed xmlns="http://www.w3.org/2005/Atom">
              <entry>
                <title>Caf&#233; &#x2014; Tom &amp; Jerry</title>
                <id>e-1</id>
                <author><name>O&#39;Brien</name></author>
                <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="/e1.epub"/>
              </entry>
            </feed>
        """.trimIndent()

        val book = OpdsFeedParser.parse(xml, baseUrl, connectionId).items.single()

        assertEquals("Café — Tom & Jerry", book.title)
        assertEquals(listOf("O'Brien"), book.authors)
    }

    @Test
    fun a_bare_opds2_publication_document_parses_as_one_publication() {
        val parsed = OpdsFeedParser.parse(
            """
            {
              "metadata": {
                "@type": "http://schema.org/Audiobook",
                "identifier": "urn:uuid:single",
                "title": "A Single Publication",
                "author": "Solo Author",
                "description": "Everything about one book.",
                "duration": 5400,
                "numberOfPages": 312,
                "language": "en"
              },
              "links": [
                { "rel": "self", "href": "/pub/1", "type": "application/opds-publication+json" },
                {
                  "rel": "http://opds-spec.org/acquisition/open-access",
                  "href": "/pub/1.epub",
                  "type": "application/epub+zip"
                }
              ],
              "images": [{ "href": "/pub/1.jpg", "type": "image/jpeg" }]
            }
            """.trimIndent(),
            baseUrl,
            connectionId,
        )

        val publication = parsed.publications.single()
        assertTrue(parsed.isSinglePublicationDocument)
        assertEquals("urn:uuid:single", publication.id)
        assertEquals("A Single Publication", publication.summary.title)
        assertEquals("Everything about one book.", publication.summary.description)
        assertEquals(5400L, publication.summary.durationSeconds)
        assertEquals(312, publication.summary.pageCount)
        assertEquals("https://opds.example.com/pub/1.epub", publication.summary.opdsAcquisitionUrl)
        assertEquals("https://opds.example.com/pub/1.jpg", publication.summary.thumbnailUrl)
    }

    @Test
    fun a_feed_with_a_publications_array_is_not_read_as_a_single_publication() {
        val parsed = OpdsFeedParser.parse(
            """
            {
              "metadata": { "title": "A Feed" },
              "navigation": [
                { "href": "/new", "title": "New", "type": "application/opds+json" }
              ]
            }
            """.trimIndent(),
            baseUrl,
            connectionId,
        )

        assertTrue(parsed.publications.isEmpty())
        assertFalse(parsed.isSinglePublicationDocument)
        assertEquals(1, parsed.navigationLinks.size)
    }

    @Test
    fun a_feed_that_happens_to_carry_one_publication_is_still_a_feed() {
        val parsed = OpdsFeedParser.parse(
            """
            {
              "metadata": { "title": "One Result" },
              "publications": [
                {
                  "metadata": { "identifier": "urn:uuid:only", "title": "Only Match" },
                  "links": [
                    {
                      "rel": "http://opds-spec.org/acquisition/open-access",
                      "href": "/only.epub",
                      "type": "application/epub+zip"
                    }
                  ]
                }
              ]
            }
            """.trimIndent(),
            baseUrl,
            connectionId,
        )

        assertEquals(1, parsed.publications.size)
        assertFalse(parsed.isSinglePublicationDocument)
    }

    @Test
    fun a_cover_that_is_not_http_is_dropped() {
        val parsed = OpdsFeedParser.parse(
            """
            {
              "publications": [
                {
                  "metadata": { "identifier": "urn:uuid:js", "title": "Sketchy" },
                  "links": [
                    {
                      "rel": "http://opds-spec.org/acquisition/open-access",
                      "href": "/ok.epub",
                      "type": "application/epub+zip"
                    }
                  ],
                  "images": [{ "href": "javascript:alert(1)", "type": "image/jpeg" }]
                }
              ]
            }
            """.trimIndent(),
            baseUrl,
            connectionId,
        )

        assertNull(parsed.publications.single().summary.thumbnailUrl)
    }

    @Test
    fun html_navigation_is_retained_as_a_non_traversable_web_catalog() {
        val parsed = OpdsFeedParser.parse(
            """
            {
              "metadata": { "title": "Example" },
              "navigation": [
                { "href": "/new", "title": "New", "type": "application/opds+json" },
                { "href": "https://shop.example.com/store", "title": "Store", "type": "text/html; charset=utf-8" }
              ]
            }
            """.trimIndent(),
            baseUrl,
            connectionId,
        )

        assertEquals(2, parsed.navigationLinks.size)
        assertTrue(OpdsFeedParser.isWebCatalogType(parsed.navigationLinks[1].type))
        assertFalse(OpdsFeedParser.isTraversableFeedType(parsed.navigationLinks[1].type))
        assertFalse(OpdsFeedParser.isWebCatalogType(parsed.navigationLinks[0].type))
    }
}
