package com.enve.engine.backup

import kotlinx.coroutines.flow.StateFlow

data class PortableBackupPreview(
    val changes: List<SettingsBackupChange>,
    val sources: List<PortableSourcePreview>,
    val integrations: List<PortableIntegrationPreview>,
)

data class PortableSourcePreview(
    val id: String,
    val name: String,
    val address: String,
    val needsSignIn: Boolean,
)

data class PortableIntegrationPreview(val id: String, val name: String, val needsSignIn: Boolean)

data class PortableRestoreResult(
    val settingsSaved: Boolean,
    val restoredSources: Int,
    val keptSources: Int,
    val signInsNeeded: Int,
    val integrationsRestored: Int,
    val integrationsToReconnect: List<String>,
)

interface SettingsTransferOffer : AutoCloseable {
    val code: String
    suspend fun awaitTransfer()
}

interface SettingsCodeOffer : SettingsTransferOffer {
    val awaitingApproval: StateFlow<Boolean>
    fun approve()
}

interface SettingsTransferReview {
    val preview: PortableBackupPreview
    suspend fun restore(settings: Boolean, sourceIds: Set<String>, integrationIds: Set<String>): PortableRestoreResult
}

interface SettingsTransferFacade {
    suspend fun send(includeSettings: Boolean, includeSources: Boolean, includeIntegrations: Boolean, includeSignIns: Boolean): SettingsTransferOffer
    suspend fun receive(code: String): SettingsTransferReview
    suspend fun sendCode(includeSettings: Boolean, includeSources: Boolean, includeIntegrations: Boolean, includeSignIns: Boolean): SettingsCodeOffer
    suspend fun receiveCode(code: String): SettingsTransferReview
    suspend fun exportFile(uri: String, includeSettings: Boolean, includeSources: Boolean, includeIntegrations: Boolean, includeSignIns: Boolean, passphrase: String)
    suspend fun importFile(uri: String, passphrase: String): SettingsTransferReview
}
