package com.enve.app.data.repository

import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.provider.CatalogImportReport
import com.enve.core.data.provider.CatalogRejectionReason
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class CatalogImportStoreTest {
    @get:Rule val temporary = TemporaryFolder()

    private fun locations(): ProfileStorageLocations = ProfileStorageLocations.forProfile(
        DEFAULT_ADULT_PROFILE_ID, temporary.root, temporary.root, temporary.root,
    )

    private fun report() = CatalogImportReport(
        acceptedCount = 4999, rejections = mapOf(CatalogRejectionReason.MISSING_ID to 1),
    )

    @Test fun diagnosticsSurviveReloadWithoutPrivateIdentifiers() {
        val store = CatalogImportStore(locations())
        store.record("private.invalid/user-a", "1", report())
        val reloaded = CatalogImportStore(locations())
        assertTrue(reloaded.hasIssue("private.invalid/user-a", "1"))
        assertEquals(1, reloaded.issues.value.single().report.rejectedCount)
        val persisted = temporary.root.resolve("catalog-import-status.json").readText()
        assertFalse(persisted.contains("private.invalid"))
        assertFalse(persisted.contains("user-a"))
    }

    @Test fun successClearsOnlyItsOwnConnectionAndLibrary() {
        val store = CatalogImportStore(locations())
        store.record("account-a", "1", report())
        store.record("account-a", "2", report())
        store.record("account-b", "1", report())
        store.record("account-a", "1", null)
        assertFalse(store.hasIssue("account-a", "1"))
        assertTrue(store.hasIssue("account-a", "2"))
        assertTrue(store.hasIssue("account-b", "1"))
        store.clearConnection("account-a")
        assertEquals(1, store.issues.value.size)
        assertTrue(store.hasIssue("account-b", "1"))
    }

    @Test fun compositeAndRawLibraryScopesMatch() {
        val store = CatalogImportStore(locations())
        store.record("account-a", "account-a::1", report())
        assertTrue(store.hasIssue("account-a", "1"))
        assertFalse(store.hasIssue("account-b", "1"))
        assertFalse(store.hasIssue("account-a", "2"))
    }
}
