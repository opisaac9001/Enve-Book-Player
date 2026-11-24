package com.enve.app.ui.screens

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CalibreCatalogUrlTest {
    @Test
    fun preservesServerPrefixPortAndExistingCatalog() {
        assertEquals("http://192.168.1.5:8080/opds", calibreCatalogUrl(" http://192.168.1.5:8080 "))
        assertEquals("https://example.org/calibre/opds", calibreCatalogUrl("https://example.org/calibre/"))
        assertEquals("https://example.org/calibre/opds", calibreCatalogUrl("https://example.org/calibre/opds#books"))
    }

    @Test
    fun requiresWebAddressAndSeparateCredentials() {
        assertNull(calibreCatalogUrl("file:///books"))
        assertNull(calibreCatalogUrl("http://user:password@example.org"))
        assertNull(calibreCatalogUrl("192.168.1.5:8080"))
    }
}
