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
    private val dismissedFile = File(locations.filesDirectory, "catalog-import-dismissed.json")
    private var dismissed = load(dismissedFile)
    private val _issues = MutableStateFlow(load(file))
    private val _visibleIssues = MutableStateFlow(_issues.value.filterNot { it in dismissed })
    val visibleIssues: StateFlow<List<CatalogImportIssue>> = _visibleIssues.asStateFlow()
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
        dismissed = dismissed.filterNot { it.scopeKey == key }
        persistDismissed()
        save(updated)
    }

    @Synchronized
    fun record(issues: List<CatalogImportIssue>) {
        val keys = issues.mapTo(mutableSetOf()) { it.scopeKey }
        dismissed = dismissed.filterNot { it.scopeKey in keys }
        persistDismissed()
        save(this.issues.value.filterNot { it.scopeKey in keys } + issues.filterNot { it.report.isComplete })
    }

    @Synchronized
    fun clearConnection(connectionId: String) {
        save(issues.value.filterNot { it.connectionKey == catalogImportConnectionKey(connectionId) })
    }

    @Synchronized
    fun dismiss(issues: List<CatalogImportIssue>) {
        dismissed = (dismissed + issues.filter { it in this.issues.value }).distinct()
        persistDismissed()
        _visibleIssues.value = this.issues.value.filterNot { it in dismissed }
    }

    private fun persistDismissed() {
        try {
            dismissedFile.parentFile?.mkdirs()
            val temporary = File(dismissedFile.parentFile, dismissedFile.name + ".tmp")
            temporary.writeText(json.encodeToString(dismissed))
            if (!temporary.renameTo(dismissedFile)) throw IOException("Diagnostic write failed")
        } catch (_: IOException) {
            android.util.Log.w("CatalogImportStore", "Could not save dismissed import notices")
        }
    }

    private fun save(updated: List<CatalogImportIssue>) {
        dismissed = dismissed.filter { it in updated }
        _visibleIssues.value = updated.filterNot { it in dismissed }
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

    private fun load(file: File): List<CatalogImportIssue> = try {
        if (!file.exists()) emptyList() else json.decodeFromString<List<CatalogImportIssue>>(file.readText())
    } catch (_: IOException) {
        emptyList()
    } catch (_: kotlinx.serialization.SerializationException) {
        emptyList()
    }
}
