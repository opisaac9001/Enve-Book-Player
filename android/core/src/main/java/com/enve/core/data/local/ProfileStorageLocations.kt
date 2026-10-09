package com.enve.core.data.local

import android.content.Context
import java.io.File

class ProfileStorageLocations private constructor(
    val profileId: String,
    val filesDirectory: File,
    val cacheDirectory: File,
    val readerDatabaseFile: File,
    val sharedDownloadsDirectory: File,
) {
    val envePreferencesFile: File = File(filesDirectory, "datastore/enve_prefs.preferences_pb")
    val hearthPreferencesFile: File = File(filesDirectory, "datastore/hearth_prefs.preferences_pb")
    val historySessionsFile: File = File(filesDirectory, "history/history_sessions.json")

    companion object {
        fun forProfile(context: Context, profileId: String): ProfileStorageLocations = forProfile(
            profileId = profileId,
            filesDirectory = context.filesDir,
            cacheDirectory = context.cacheDir,
            databaseDirectory = checkNotNull(context.getDatabasePath("reader.db").parentFile),
        )

        fun forProfile(
            profileId: String,
            filesDirectory: File,
            cacheDirectory: File,
            databaseDirectory: File,
        ): ProfileStorageLocations {
            require(FamilyProfile.validId(profileId))
            val owner = profileId == DEFAULT_ADULT_PROFILE_ID
            val relativeRoot = "profiles/$profileId"
            return ProfileStorageLocations(
                profileId = profileId,
                filesDirectory = if (owner) filesDirectory else File(filesDirectory, relativeRoot),
                cacheDirectory = if (owner) cacheDirectory else File(cacheDirectory, relativeRoot),
                readerDatabaseFile = File(
                    if (owner) databaseDirectory else File(databaseDirectory, relativeRoot),
                    "reader.db",
                ),
                sharedDownloadsDirectory = File(filesDirectory, "shared-downloads"),
            )
        }
    }
}
