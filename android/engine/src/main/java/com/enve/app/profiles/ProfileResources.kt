package com.enve.app.profiles

import android.content.Context
import com.enve.app.auth.MtlsManager
import com.enve.app.data.local.ReaderDatabase
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.local.ProfilePreferences
import com.enve.core.data.local.ProfileStorageLocations
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext

class ProfileResources private constructor(
    val context: Context,
    val locations: ProfileStorageLocations,
    val database: ReaderDatabase,
    val profilePreferences: ProfilePreferences,
    val vault: CredentialVault,
    val preferences: PreferencesManager,
    val connections: ConnectionRegistry,
    val mtlsManager: MtlsManager,
    val scope: CoroutineScope,
    private val preferenceScope: CoroutineScope,
) {
    suspend fun close() = withContext(NonCancellable) {
        scope.coroutineContext[Job]?.cancelAndJoin()
        preferenceScope.coroutineContext[Job]?.cancelAndJoin()
        if (locations.profileId != DEFAULT_ADULT_PROFILE_ID) database.close()
    }

    companion object {
        suspend fun open(context: Context, profileId: String): ProfileResources = withContext(Dispatchers.IO) {
            val appContext = context.applicationContext
            val locations = ProfileStorageLocations.forProfile(appContext, profileId)
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
            val preferenceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            var database: ReaderDatabase? = null
            try {
                val stores = ProfilePreferences.open(appContext, locations, preferenceScope)
                stores.enve.data.first()
                stores.hearth.data.first()
                val vault = CredentialVault.forProfile(appContext, profileId)
                val preferences = PreferencesManager(stores.enve, vault, scope)
                val connections = ConnectionRegistry(stores.enve)
                database = if (profileId == DEFAULT_ADULT_PROFILE_ID) ReaderDatabase.getInstance(appContext)
                    else ReaderDatabase.open(appContext, locations)
                ProfileResources(
                    appContext, locations, database, stores, vault, preferences, connections,
                    MtlsManager(vault, connections), scope, preferenceScope,
                )
            } catch (error: Throwable) {
                withContext(NonCancellable) {
                    scope.coroutineContext[Job]?.cancelAndJoin()
                    preferenceScope.coroutineContext[Job]?.cancelAndJoin()
                    if (profileId != DEFAULT_ADULT_PROFILE_ID) database?.close()
                }
                throw error
            }
        }
    }
}
