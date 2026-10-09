package com.enve.app.data.podcasts

import android.content.Context
import android.content.SharedPreferences
import com.enve.core.data.local.DEFAULT_ADULT_PROFILE_ID
import com.enve.core.data.local.ProfileStorageLocations
import dagger.hilt.android.qualifiers.ApplicationContext
import com.enve.engine.podcasts.PodcastSubscription
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PodcastSubscriptionStore(private val preferences: SharedPreferences) {
    @Inject
    constructor(@ApplicationContext context: Context) : this(
        context.getSharedPreferences("podcast_subscriptions", Context.MODE_PRIVATE),
    )

    constructor(context: Context, locations: ProfileStorageLocations) : this(
        context.getSharedPreferences(
            if (locations.profileId == DEFAULT_ADULT_PROFILE_ID) "podcast_subscriptions"
            else "podcast_subscriptions_profile_${locations.profileId}",
            Context.MODE_PRIVATE,
        ),
    )

    private val json = Json { ignoreUnknownKeys = true }
    private val mutableSubscriptions = MutableStateFlow(
        preferences.getString("shows", null)?.let { stored ->
            runCatching { json.decodeFromString<List<PodcastSubscription>>(stored) }.getOrNull()
        }.orEmpty(),
    )

    val subscriptions: StateFlow<List<PodcastSubscription>> = mutableSubscriptions

    @Synchronized
    fun save(subscription: PodcastSubscription) {
        val updated = mutableSubscriptions.value.filterNot { it.feedUrl == subscription.feedUrl } + subscription
        persist(updated)
    }

    @Synchronized
    fun remove(feedUrl: String) {
        persist(mutableSubscriptions.value.filterNot { it.feedUrl == feedUrl })
    }

    private fun persist(subscriptions: List<PodcastSubscription>) {
        preferences.edit().putString("shows", json.encodeToString(subscriptions)).apply()
        mutableSubscriptions.value = subscriptions
    }
}
