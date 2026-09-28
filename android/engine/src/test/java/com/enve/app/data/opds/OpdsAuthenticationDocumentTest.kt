package com.enve.app.data.opds

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsAuthenticationDocumentTest {

    private val baseUrl = "https://opds.example.com/auth"

    @Test
    fun a_basic_document_reports_its_labels() {
        val document = parseOpdsAuthenticationDocument(
            """
            {
              "id": "https://opds.example.com/auth",
              "title": "Example Library",
              "description": "Sign in with your library card",
              "authentication": [
                {
                  "type": "http://opds-spec.org/auth/basic",
                  "labels": { "login": "Card number", "password": "PIN" }
                }
              ],
              "links": [
                { "rel": "logo", "href": "/logo.png" },
                { "rel": "help", "href": "https://help.example.com" }
              ]
            }
            """.trimIndent(),
            baseUrl,
        )

        val method = document!!.methods.single()
        assertEquals("Example Library", document.title)
        assertEquals(OpdsAuthenticationFlow.BASIC, method.flow)
        assertEquals("Card number", method.labels.login)
        assertEquals("PIN", method.labels.password)
        assertEquals(listOf("https://help.example.com"), document.helpUrls)
    }

    @Test
    fun oauth_endpoints_are_resolved_against_the_document_url() {
        val document = parseOpdsAuthenticationDocument(
            """
            {
              "authentication": [
                {
                  "type": "http://opds-spec.org/auth/oauth/password",
                  "links": [
                    { "rel": "authenticate", "href": "/oauth/token" },
                    { "rel": "refresh", "href": "/oauth/refresh" }
                  ]
                }
              ]
            }
            """.trimIndent(),
            baseUrl,
        )

        val method = document!!.methods.single()
        assertEquals(OpdsAuthenticationFlow.OAUTH_PASSWORD, method.flow)
        assertEquals("https://opds.example.com/oauth/token", method.authenticateUrl)
        assertEquals("https://opds.example.com/oauth/refresh", method.refreshUrl)
    }

    @Test
    fun the_preferred_method_skips_types_this_app_cannot_drive() {
        val document = parseOpdsAuthenticationDocument(
            """
            {
              "authentication": [
                { "type": "http://opds-spec.org/auth/local" },
                {
                  "type": "http://opds-spec.org/auth/oauth/implicit",
                  "links": [{ "rel": "authenticate", "href": "/oauth/authorize" }]
                },
                { "type": "http://opds-spec.org/auth/basic" }
              ]
            }
            """.trimIndent(),
            baseUrl,
        )!!

        assertEquals(
            listOf(
                OpdsAuthenticationFlow.UNSUPPORTED,
                OpdsAuthenticationFlow.OAUTH_IMPLICIT,
                OpdsAuthenticationFlow.BASIC,
            ),
            document.methods.map { it.flow },
        )
    }

    @Test
    fun a_non_authentication_payload_is_not_a_document() {
        assertNull(parseOpdsAuthenticationDocument(null, baseUrl))
        assertNull(parseOpdsAuthenticationDocument("", baseUrl))
        assertNull(parseOpdsAuthenticationDocument("<feed/>", baseUrl))
        assertNull(parseOpdsAuthenticationDocument("""{"title":"no methods"}""", baseUrl))
    }

    @Test
    fun an_endpoint_that_is_not_http_is_dropped() {
        val document = parseOpdsAuthenticationDocument(
            """
            {
              "authentication": [
                {
                  "type": "http://opds-spec.org/auth/oauth/password",
                  "links": [{ "rel": "authenticate", "href": "javascript:alert(1)" }]
                }
              ]
            }
            """.trimIndent(),
            baseUrl,
        )

        assertNull(document!!.methods.single().authenticateUrl)
    }

    @Test
    fun the_discovery_request_offers_both_media_type_spellings() {
        assertTrue(OPDS_AUTHENTICATION_ACCEPT.contains("application/opds-authentication+json"))
        assertTrue(OPDS_AUTHENTICATION_ACCEPT.contains("application/vnd.opds.authentication.v1.0+json"))
    }
}
