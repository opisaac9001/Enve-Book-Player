package com.enve.app.data.sync

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.util.Log
import com.enve.core.di.ApplicationScope
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicBoolean
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class PendingBookMutationScheduler @Inject constructor(
    private val replay: PendingBookMutationReplay,
    @ApplicationContext private val context: Context,
    @ApplicationScope parentScope: CoroutineScope,
) {
    private val scope = CoroutineScope(SupervisorJob(parentScope.coroutineContext[Job]) + Dispatchers.IO)
    private val watchingNetwork = AtomicBoolean(false)

    fun start() {
        if (watchingNetwork.compareAndSet(false, true)) {
            scope.launch { networkAvailability().collect { run(PendingBookMutationTrigger.NETWORK) } }
        }
        request(PendingBookMutationTrigger.START)
    }

    fun request(trigger: PendingBookMutationTrigger) {
        scope.launch { run(trigger) }
    }

    private suspend fun run(trigger: PendingBookMutationTrigger) {
        try {
            replay.replay(trigger)
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (failure: Exception) {
            Log.w(TAG, "Pending book edits could not be replayed: ${failure.javaClass.simpleName}")
        }
    }

    private fun networkAvailability(): Flow<Unit> = callbackFlow {
        val manager = checkNotNull(context.getSystemService(ConnectivityManager::class.java))
        val alreadyOnline = AtomicBoolean(manager.activeNetwork != null)
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if (!alreadyOnline.getAndSet(false)) trySend(Unit)
            }
        }
        manager.registerDefaultNetworkCallback(callback)
        awaitClose { manager.unregisterNetworkCallback(callback) }
    }

    private companion object {
        const val TAG = "PendingBookMutations"
    }
}
