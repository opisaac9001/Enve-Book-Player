package com.enve.app.data.repository

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OpdsProgressionDiscoveryTest {

    private val baseUrl = "https://opds.example.com/v1/catalog"
    private val connectionId = "conn-opds"

    @Test
    fun finds_the_progression_service_in_an_opds_1_x_entry() {
        val publication = parseXml(
            """<link rel="http://opds-spec.org/progression" href="/019c0435/progression" type="application/opds-progression+json"/>""",
        )

        assertEquals("https://opds.example.com/019c0435/progression", publication.progressionUrl)
        assertEquals("https://opds.example.com/019c0435/progression", publication.summary.opdsProgressionUrl)
    }

    @Test
    fun ignores_opds_1_x_links_that_do_not_match_both_the_rel_and_the_media_type() {
        assertNull(
            parseXml(
                """<link rel="http://opds-spec.org/progression" href="/p" type="application/json"/>""",
            ).progressionUrl,
        )
        assertNull(
            parseXml(
                """<link rel="http://opds-spec.org/progressions" href="/p" type="application/opds-progression+json"/>""",
            ).progressionUrl,
        )
        assertNull(parseXml("").progressionUrl)
    }

    @Test
    fun accepts_a_media_type_with_parameters() {
        val publication = parseXml(
            """<link rel="http://opds-spec.org/progression" href="/p" type="application/opds-progression+json; charset=utf-8"/>""",
        )

        assertEquals("https://opds.example.com/p", publication.progressionUrl)
    }

    @Test
    fun finds_the_progression_service_in_an_opds_2_0_publication() {
        val feed = """
            {
              "metadata": { "title": "Example Catalog" },
              "publications": [
                {
                  "metadata": { "title": "Moby-Dick", "identifier": "urn:isbn:9780000000000" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/moby.epub", "type": "application/epub+zip" },
                    {
                      "rel": ["http://opds-spec.org/progression"],
                      "href": "https://opds.example.com/019c0435-5361-7e59-89b7-4ee01a6d87b8/progression",
                      "type": "application/opds-progression+json",
                      "properties": {
                        "authenticate": {
                          "href": "https://opds.example.com/authentication.json",
                          "type": "application/opds-authentication+json"
                        }
                      }
                    }
                  ]
                }
              ]
            }
        """.trimIndent()

        val publication = OpdsFeedParser.parse(feed, baseUrl, connectionId).publications.single()

        assertEquals(
            "https://opds.example.com/019c0435-5361-7e59-89b7-4ee01a6d87b8/progression",
            publication.progressionUrl,
        )
        assertEquals(publication.progressionUrl, publication.summary.opdsProgressionUrl)
        assertEquals("https://opds.example.com/moby.epub", publication.summary.opdsAcquisitionUrl)
        assertEquals("https://opds.example.com/authentication.json", publication.progressionAuthenticateUrl)
    }

    @Test
    fun a_progression_link_without_an_authenticate_hint_carries_none() {
        val feed = """
            {
              "metadata": { "title": "Example Catalog" },
              "publications": [
                {
                  "metadata": { "title": "Moby-Dick", "identifier": "urn:isbn:9780000000000" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/moby.epub", "type": "application/epub+zip" },
                    {
                      "rel": "http://opds-spec.org/progression",
                      "href": "/p",
                      "type": "application/opds-progression+json"
                    }
                  ]
                }
              ]
            }
        """.trimIndent()

        val publication = OpdsFeedParser.parse(feed, baseUrl, connectionId).publications.single()

        assertEquals("https://opds.example.com/p", publication.progressionUrl)
        assertNull(publication.progressionAuthenticateUrl)
    }

    @Test
    fun an_authenticate_hint_is_resolved_against_the_feed_base_url() {
        val feed = """
            {
              "metadata": { "title": "Example Catalog" },
              "publications": [
                {
                  "metadata": { "title": "Moby-Dick", "identifier": "urn:isbn:9780000000000" },
                  "links": [
                    { "rel": "http://opds-spec.org/acquisition", "href": "/moby.epub", "type": "application/epub+zip" },
                    {
                      "rel": "http://opds-spec.org/progression",
                      "href": "https://progression.example.net/p",
                      "type": "application/opds-progression+json",
                      "properties": { "authenticate": { "href": "/authentication.json" } }
                    }
                  ]
                }
              ]
            }
        """.trimIndent()

        val publication = OpdsFeedParser.parse(feed, baseUrl, connectionId).publications.single()

        assertEquals("https://progression.example.net/p", publication.progressionUrl)
        assertEquals("https://opds.example.com/authentication.json", publication.progressionAuthenticateUrl)
    }

    @Test
    fun a_progression_link_is_never_mistaken_for_an_acquisition_or_a_navigation_branch() {
        val publication = parseXml(
            """<link rel="http://opds-spec.org/progression" href="/p" type="application/opds-progression+json"/>""",
        )

        assertEquals(1, publication.acquisitions.size)
        assertEquals("https://opds.example.com/moby.epub", publication.acquisitions.single().href)
    }

    @Test
    fun an_opds_1_x_entry_carries_its_own_authentication_document_link_as_the_hint() {
        val publication = parseXml(
            """<link rel="http://opds-spec.org/progression" href="/p" type="application/opds-progression+json"/>""" +
                """<link rel="http://opds-spec.org/auth/document" href="/authentication.json"
                   type="application/opds-authentication+json"/>""",
        )

        assertEquals("https://opds.example.com/authentication.json", publication.progressionAuthenticateUrl)
    }

    @Test
    fun an_opds_1_x_entry_falls_back_to_the_feeds_authentication_document_link() {
        val publication = parseXml(
            """<link rel="http://opds-spec.org/progression" href="/p" type="application/opds-progression+json"/>""",
            feedLinks = """<link rel="http://opds-spec.org/auth/document" href="/feed-auth.json"
                          type="application/opds-authentication+json"/>""",
        )

        assertEquals("https://opds.example.com/feed-auth.json", publication.progressionAuthenticateUrl)
    }

    @Test
    fun an_opds_1_x_entry_without_a_progression_service_carries_no_hint() {
        val publication = parseXml(
            "",
            feedLinks = """<link rel="http://opds-spec.org/auth/document" href="/feed-auth.json"
                          type="application/opds-authentication+json"/>""",
        )

        assertNull(publication.progressionAuthenticateUrl)
    }

    private fun parseXml(progressionLink: String, feedLinks: String = ""): OpdsPublication {
        val feed = """
            <?xml version="1.0" encoding="utf-8"?>
            <feed xmlns="http://www.w3.org/2005/Atom">
              <title>Example Catalog</title>
              $feedLinks
              <entry>
                <title>Moby-Dick</title>
                <id>urn:uuid:019c0435-5361-7e59-89b7-4ee01a6d87b8</id>
                <link rel="http://opds-spec.org/acquisition" href="/moby.epub" type="application/epub+zip"/>
                $progressionLink
              </entry>
            </feed>
        """.trimIndent()
        return OpdsFeedParser.parse(feed, baseUrl, connectionId).publications.single()
    }
}
