package com.enve.app.data.opds

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class OpdsOAuthTest {

    private val nowMs = 1_700_000_000_000L
    private val state = "5a1f2c"

    @Test
    fun a_token_response_carries_its_expiry_forward() {
        val token = parseOpdsOAuthToken(
            """{"access_token":"abc","token_type":"Bearer","expires_in":3600,"refresh_token":"def"}""",
            nowMs,
        )!!

        assertEquals("abc", token.accessToken)
        assertEquals("def", token.refreshToken)
        assertEquals(nowMs + 3_600_000L, token.expiresAtMs)
    }

    @Test
    fun a_response_without_an_expiry_or_refresh_token_is_still_usable() {
        val token = parseOpdsOAuthToken("""{"access_token":"abc"}""", nowMs)!!

        assertEquals("abc", token.accessToken)
        assertNull(token.refreshToken)
        assertNull(token.expiresAtMs)
    }

    @Test
    fun a_response_this_app_cannot_present_is_rejected() {
        assertNull(parseOpdsOAuthToken(null, nowMs))
        assertNull(parseOpdsOAuthToken("""{"token_type":"Bearer"}""", nowMs))
        assertNull(parseOpdsOAuthToken("""{"access_token":"","token_type":"Bearer"}""", nowMs))
        assertNull(parseOpdsOAuthToken("""{"access_token":"abc","token_type":"MAC"}""", nowMs))
    }

    @Test
    fun an_implicit_redirect_is_read_from_the_fragment() {
        val callback = parseOpdsImplicitCallback(
            "enve://opds-auth#access_token=abc&token_type=Bearer&expires_in=7200&refresh_token=def&state=$state",
            state,
            nowMs,
        )!!

        assertEquals("abc", callback.accessToken)
        assertEquals("def", callback.refreshToken)
        assertEquals(nowMs + 7_200_000L, callback.expiresAtMs)
    }

    @Test
    fun an_implicit_redirect_reports_the_servers_error() {
        val callback = parseOpdsImplicitCallback("enve://opds-auth#error=access_denied&state=$state", state, nowMs)!!

        assertEquals("", callback.accessToken)
        assertEquals("access_denied", callback.error)
    }

    @Test
    fun a_redirect_without_a_token_is_not_a_sign_in() {
        assertNull(parseOpdsImplicitCallback("enve://opds-auth", state, nowMs))
        assertNull(parseOpdsImplicitCallback("enve://opds-auth#state=$state", state, nowMs))
        assertNull(
            parseOpdsImplicitCallback("enve://opds-auth#access_token=abc&token_type=MAC&state=$state", state, nowMs),
        )
    }

    @Test
    fun a_redirect_whose_state_does_not_match_the_flow_is_rejected() {
        assertNull(parseOpdsImplicitCallback("enve://opds-auth#access_token=abc", state, nowMs))
        assertNull(parseOpdsImplicitCallback("enve://opds-auth#access_token=abc&state=", state, nowMs))
        assertNull(parseOpdsImplicitCallback("enve://opds-auth#access_token=abc&state=other", state, nowMs))
        assertNull(parseOpdsImplicitCallback("enve://opds-auth#error=access_denied&state=other", state, nowMs))
        assertNull(
            parseOpdsImplicitCallback("enve://opds-auth#access_token=abc&state=$state", "", nowMs),
        )
    }

    @Test
    fun a_query_style_redirect_is_never_treated_as_a_token() {
        assertNull(parseOpdsImplicitCallback("enve://opds-auth?access_token=abc&state=$state", state, nowMs))
        assertNull(parseOpdsImplicitCallback("enve://opds-auth?error=access_denied&state=$state", state, nowMs))
    }
}
