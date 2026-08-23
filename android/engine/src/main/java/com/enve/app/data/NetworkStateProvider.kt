package com.enve.app.data

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class NetworkStateProvider @Inject constructor(
    @ApplicationContext private val context: Context,
) {
    private val cm get() = context.getSystemService(ConnectivityManager::class.java)

    fun isActiveNetworkMetered(): Boolean {
        val manager = cm ?: return false
        val caps = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
        if (!caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return false
        return !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
    }
}
