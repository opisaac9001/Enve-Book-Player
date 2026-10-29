package com.enve.app.ui.screens

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.enve.app.EnveApplication
import com.enve.core.data.model.BookSource
import com.enve.core.data.provider.CatalogFailureKind
import com.enve.core.data.provider.CatalogRejectionReason
import com.enve.core.data.provider.catalogImportConnectionKey
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class GrimmoryCatalogImportVerificationTest {
    @Test fun incompleteImportsPreserveRoomCacheAcrossAccountsAndRecover() = runBlocking {
        assumeTrue(InstrumentationRegistry.getArguments().getString("enveCatalogFixture") == "1")
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        check(context.packageName == "com.enve.app.debug")
        val app = context.applicationContext as EnveApplication
        app.profiles.initialize()
        val runtime = checkNotNull(app.profiles.activeRuntime.value).component
        val connections = runtime.connections().connections.first()
        check(connections.size == 2 && connections.all {
            it.source == BookSource.GRIMMORY && it.serverUrl.trimEnd('/') == "http://10.0.2.2:18787" &&
                it.username in setOf("fixture", "restricted")
        })
        val owner = connections.single { it.username == "fixture" }
        val restricted = connections.single { it.username == "restricted" }
        val cache = runtime.libraryCache()
        val dao = runtime.bookCacheDao()
        val evidence = JSONArray()

        fun mode(value: String, total: Int, name: String) {
            val connection = URI("http://10.0.2.2:18787/control?mode=$value&total=$total&case=$name").toURL().openConnection() as HttpURLConnection
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            try { check(connection.responseCode == 200); connection.inputStream.close() }
            finally { connection.disconnect() }
        }

        suspend fun runCase(value: String, expected: Int, total: Int = 5000, name: String = value, reindex: Boolean = false) {
            mode(value, total, name)
            if (reindex) cache.invalidateAndRefresh(listOf(owner.id)) else cache.refreshNow()
            assertEquals(name, expected, dao.countForConnection(owner.id))
            val listed = cache.libraries.first()
            assertEquals("Fixture Owner Books", listed.single { it.connectionId == owner.id }.name)
            assertEquals("Fixture Restricted Books", listed.single { it.connectionId == restricted.id }.name)

            assertEquals("Restricted account must not receive owner books", 0, dao.countForConnection(restricted.id))
            val complete = value in setOf("healthy", "legacy-repeat", "missing-title") || total == 0
            val issues = withTimeout(5000) { cache.importIssues.first { current ->
                val ownerIssues = current.filter { it.connectionKey == catalogImportConnectionKey(owner.id) }
                val readerIssues = current.filter { it.connectionKey == catalogImportConnectionKey(restricted.id) }
                readerIssues.isNotEmpty() && if (complete) ownerIssues.isEmpty() else when (value) {
                    "late-http" -> ownerIssues.any { issue -> issue.report.failures.any { it.kind == CatalogFailureKind.HTTP } }
                    "late-parse" -> ownerIssues.any { issue -> issue.report.failures.any { it.kind == CatalogFailureKind.INVALID_PAGE } }
                    "late-timeout" -> ownerIssues.any { issue -> issue.report.failures.any { it.kind == CatalogFailureKind.NETWORK } }
                    else -> ownerIssues.any { it.report.rejectedCount == 1 }
                }
            } }
            val own = issues.filter { it.connectionKey == catalogImportConnectionKey(owner.id) }
            val denied = issues.filter { it.connectionKey == catalogImportConnectionKey(restricted.id) }
            assertTrue("Restricted account remains incomplete", denied.any { issue ->
                issue.report.failures.any { it.kind == CatalogFailureKind.ACCESS_DENIED }
            })
            if (complete) {
                assertTrue("Successful owner import must clear only its own diagnostic", own.isEmpty())
            } else assertTrue("Incomplete owner import needs diagnostics", own.isNotEmpty())
            if (value in setOf("missing-first", "missing-last", "partial-renamed")) {
                assertEquals(1, own.sumOf { it.report.rejections[CatalogRejectionReason.MISSING_ID] ?: 0 })
            }
            evidence.put(JSONObject().put("case", name).put("owner_books", expected).put("restricted_books", 0)
                .put("owner_incomplete", own.isNotEmpty()).put("restricted_incomplete", true))
            File(context.getExternalFilesDir(null), "catalog-import-verification.json").writeText(evidence.toString(2))
        }

        runCase("healthy", 5000)
        val originalTitles = dao.observeAllForList().first().associate { it.id to it.title }
        assertEquals(5000, originalTitles.size)
        runCase("partial-renamed", 5000, reindex = true)
        assertTrue("Incomplete refresh must preserve validated metadata", originalTitles ==
            dao.observeAllForList().first().associate { it.id to it.title })
        if (InstrumentationRegistry.getArguments().getString("enveCatalogReindexOnly") == "1") return@runBlocking
        runCase("missing-first", 5000)
        runCase("missing-last", 5000)
        runCase("late-http", 5000)
        runCase("late-parse", 5000)
        runCase("late-timeout", 5000)
        runCase("missing-title", 5000)
        runCase("healthy", 4900, total = 4900, name = "authoritative-removals")
        runCase("healthy", 0, total = 0, name = "authoritative-empty")
        runCase("missing-first", 4999, name = "fresh-missing-first")
        runCase("healthy", 0, total = 0, name = "empty-before-last")
        runCase("missing-last", 4999, name = "fresh-missing-last")
        runCase("healthy", 0, total = 0, name = "empty-before-http")
        runCase("late-http", 4500, name = "fresh-http")
        runCase("healthy", 5000, name = "full-recovery")
        runCase("legacy-repeat", 5000, name = "unpaged-legacy")
        runCase("healthy", 0, total = 0, name = "empty-before-parse")
        runCase("late-parse", 4500, name = "fresh-parse")
        runCase("healthy", 0, total = 0, name = "empty-before-final")
        runCase("missing-last", 4999, name = "final-partial-ui")
    }
}
