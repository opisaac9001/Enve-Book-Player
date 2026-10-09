package com.enve.core.data.local

import android.content.Context
import android.content.SharedPreferences
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class HearthDismissedShelfStore(private val prefs: SharedPreferences) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(
        context.getSharedPreferences("hearth_dismissed_shelves", Context.MODE_PRIVATE),
    )

    constructor(context: Context, locations: ProfileStorageLocations) : this(
        context.getSharedPreferences(
            if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) "hearth_dismissed_shelves"
            else "hearth_dismissed_shelves_profile_${locations.profileId}",
            Context.MODE_PRIVATE,
        ),
    )

    private val mutableKeys = MutableStateFlow(prefs.getStringSet("book_keys", emptySet()).orEmpty().toSet())

    val keys: StateFlow<Set<String>> = mutableKeys

    fun dismiss(bookKey: String) {
        val updated = mutableKeys.value + bookKey
        mutableKeys.value = updated
        prefs.edit().putStringSet("book_keys", updated).apply()
    }
}
