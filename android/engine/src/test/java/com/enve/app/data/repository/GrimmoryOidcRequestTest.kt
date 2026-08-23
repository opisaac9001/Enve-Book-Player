package com.enve.app.data.repository

import okhttp3.Request
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class GrimmoryOidcRequestTest {

    @Test
    fun protectedServerRequestsCarryBrowserAndServiceHeaders() {
        val request = Request.Builder()
            .url("https://grimmory.example/api/v1/auth/oidc/callback")
            .header("Accept", "application/json")
            .applyGrimmoryOidcHeaders(
                mapOf(
                    "Cookie" to "CF_Authorization=browser-token; CF_Binding=binding-token",
                    "CF-Access-Client-Id" to "client-id",
                    "CF-Access-Client-Secret" to "client-secret",
                )
            )
            .build()

        assertEquals(
            "CF_Authorization=browser-token; CF_Binding=binding-token",
            request.header("Cookie"),
        )
        assertEquals("client-id", request.header("CF-Access-Client-Id"))
        assertEquals("client-secret", request.header("CF-Access-Client-Secret"))
        assertEquals("application/json", request.header("Accept"))
    }

    @Test
    fun defaultScopesMatchIosWithoutImplicitOfflineAccess() {
        assertEquals("openid profile email groups", grimmoryOidcScopes(null))
        assertEquals("openid profile email groups", grimmoryOidcScopes(""))
        assertEquals(
            "openid profile email groups offline_access",
            grimmoryOidcScopes("openid profile email groups offline_access"),
        )
        assertNull(
            grimmoryOidcScopes(null)
                .split(' ')
                .firstOrNull { it == "offline_access" }
        )
    }

    @Test
    fun usernameLookupAcceptsNumericGrimmoryUserIds() {
        assertEquals(
            "enve-admin",
            grimmoryOidcUsername("""{"id":1,"username":"enve-admin"}"""),
        )
    }
}
