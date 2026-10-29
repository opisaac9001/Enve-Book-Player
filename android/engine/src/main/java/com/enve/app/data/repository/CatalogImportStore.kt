package com.enve.app.data.repository

import com.enve.core.data.local.ProfileStorageLocations
import com.enve.core.data.provider.CatalogImportIssue
import com.enve.core.data.provider.CatalogImportReport
import com.enve.core.data.provider.catalogImportConnectionKey
import com.enve.core.data.provider.catalogImportScopeKey
import java.io.File
import java.io.IOException
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Singleton
class CatalogImportStore @Inject constructor(locations: ProfileStorageLocations) {
    private val file = File(locations.filesDirectory, "catalog-import-status.json")
    private val json = Json { ignoreUnknownKeys = true }
    private val _issues = MutableStateFlow(load())
    val issues: StateFlow<List<CatalogImportIssue>> = _issues.asStateFlow()

    fun hasIssue(connectionId: String?, libraryId: String?): Boolean =
        issues.value.any { it.scopeKey == catalogImportScopeKey(connectionId, libraryId) }

    @Synchronized
    fun record(connectionId: String?, libraryId: String?, report: CatalogImportReport?) {
        val key = catalogImportScopeKey(connectionId, libraryId)
        val retained = issues.value.filterNot { it.scopeKey == key }
        val updated = if (report == null || report.isComplete) retained else retained + CatalogImportIssue(
            connectionKey = catalogImportConnectionKey(connectionId), scopeKey = key, report = report,
        )
        save(updated)
    }

    @Synchronized
    fun record(issues: List<CatalogImportIssue>) {
        val keys = issues.mapTo(mutableSetOf()) { it.scopeKey }
        save(this.issues.value.filterNot { it.scopeKey in keys } + issues.filterNot { it.report.isComplete })
    }

    @Synchronized
    fun clearConnection(connectionId: String) {
        save(issues.value.filterNot { it.connectionKey == catalogImportConnectionKey(connectionId) })
    }

    private fun save(updated: List<CatalogImportIssue>) {
        if (updated == issues.value) return
        _issues.value = updated
        try {
            file.parentFile?.mkdirs()
            val temporary = File(file.parentFile, file.name + ".tmp")
            temporary.writeText(json.encodeToString(updated))
            if (!temporary.renameTo(file)) throw IOException("Diagnostic write failed")
        } catch (_: IOException) {
            android.util.Log.w("CatalogImportStore", "Could not save library import status")
        }
    }

    private fun load(): List<CatalogImportIssue> = try {
        if (!file.exists()) emptyList() else json.decodeFromString<List<CatalogImportIssue>>(file.readText())
    } catch (_: IOException) {
        emptyList()
    } catch (_: kotlinx.serialization.SerializationException) {
        emptyList()
    }
}
