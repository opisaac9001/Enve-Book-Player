package com.enve.app.data.opds

import okhttp3.HttpUrl.Companion.toHttpUrl
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class OpdsImplicitFlowTest {

    private val state = "9f2c4b"

    @Test
    fun an_implicit_authorize_url_gains_the_response_type_redirect_and_state() {
        val url = buildOpdsImplicitAuthorizeUrl(
            "https://opds.example.com/oauth/authorize?client_id=enve",
            OPDS_IMPLICIT_REDIRECT_URI,
            state,
        )!!.toHttpUrl()

        assertEquals("enve", url.queryParameter("client_id"))
        assertEquals("token", url.queryParameter("response_type"))
        assertEquals(OPDS_IMPLICIT_REDIRECT_URI, url.queryParameter("redirect_uri"))
        assertEquals(state, url.queryParameter("state"))
    }

    @Test
    fun a_prebuilt_authorize_url_never_keeps_the_servers_own_redirect_or_state() {
        val prebuilt = "https://opds.example.com/oauth/authorize" +
            "?response_type=code&redirect_uri=https%3A%2F%2Fevil.example.org&state=server-chosen"

        val url = buildOpdsImplicitAuthorizeUrl(prebuilt, OPDS_IMPLICIT_REDIRECT_URI, state)!!.toHttpUrl()

        assertEquals("token", url.queryParameter("response_type"))
        assertEquals(OPDS_IMPLICIT_REDIRECT_URI, url.queryParameter("redirect_uri"))
        assertEquals(state, url.queryParameter("state"))
    }

    @Test
    fun an_authorize_url_that_is_not_http_or_has_no_state_is_refused() {
        assertNull(buildOpdsImplicitAuthorizeUrl("javascript:alert(1)", OPDS_IMPLICIT_REDIRECT_URI, state))
        assertNull(buildOpdsImplicitAuthorizeUrl("enve://opds-auth", OPDS_IMPLICIT_REDIRECT_URI, state))
        assertNull(
            buildOpdsImplicitAuthorizeUrl("https://opds.example.com/authorize", OPDS_IMPLICIT_REDIRECT_URI, " "),
        )
    }

    @Test
    fun every_flow_gets_its_own_unguessable_state() {
        val states = List(64) { newOpdsImplicitState() }

        assertEquals(64, states.toSet().size)
        states.forEach {
            assertEquals(64, it.length)
            assertTrue(it, it.all { char -> char in "0123456789abcdef" })
        }
        assertNotEquals(states[0], states[1])
    }

    @Test
    fun only_the_configured_redirect_uri_ends_the_flow() {
        assertTrue(isOpdsImplicitRedirect("enve://opds-auth#access_token=a", OPDS_IMPLICIT_REDIRECT_URI))
        assertTrue(isOpdsImplicitRedirect("ENVE://OPDS-AUTH#access_token=a", OPDS_IMPLICIT_REDIRECT_URI))
        assertTrue(isOpdsImplicitRedirect("enve://opds-auth/#access_token=a", OPDS_IMPLICIT_REDIRECT_URI))
        assertTrue(isOpdsImplicitRedirect("enve://opds-auth?x=1#access_token=a", OPDS_IMPLICIT_REDIRECT_URI))
    }

    @Test
    fun a_uri_that_merely_starts_with_the_redirect_never_ends_the_flow() {
        listOf(
            "enve://opds-auth.evil.example.org/#access_token=a",
            "enve://opds-authority/#access_token=a",
            "enve://opds-auth/steal#access_token=a",
            "enve://opds-auth@evil.example.org/#access_token=a",
            "envex://opds-auth#access_token=a",
            "https://opds.example.com/callback",
            "not a uri at all",
        ).forEach { assertFalse(it, isOpdsImplicitRedirect(it, OPDS_IMPLICIT_REDIRECT_URI)) }
    }
}
