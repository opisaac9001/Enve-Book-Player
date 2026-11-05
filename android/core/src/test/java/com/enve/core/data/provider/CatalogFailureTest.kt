package com.enve.core.data.provider

import org.junit.Assert.*
import org.junit.Test

class CatalogFailureTest {
    @Test fun preservesHttpStatusWithoutPersistingPrivateResponseText() {
        val denied = catalogFailureFor(IllegalStateException("Komga failed HTTP 403 private-response"))
        assertEquals(CatalogFailureKind.ACCESS_DENIED, denied.kind)
        assertEquals(403, denied.httpStatus)
        assertEquals(CatalogFailureKind.HTTP, catalogFailureFor(IllegalStateException("HTTP 404 wrong-path")).kind)
        assertEquals(CatalogFailureKind.ACCESS_DENIED, catalogFailureFor(Exception("Unauthorized: private-account")).kind)
        assertEquals(CatalogFailureKind.NETWORK, catalogFailureFor(java.io.IOException("private.invalid")).kind)
    }
}
