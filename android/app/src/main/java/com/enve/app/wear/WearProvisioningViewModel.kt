package com.enve.app.wear

import android.content.Context
import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.ProviderConnection
import com.enve.wear.protocol.WearProtocol
import com.enve.wear.protocol.WearProvisionedConnection
import com.enve.wear.protocol.WearProvisioningCrypto
import com.enve.wear.protocol.WearProvisioningResult
import com.google.android.gms.tasks.Task
import com.google.android.gms.wearable.Wearable
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

data class WearProvisioningUiState(
    val sendingConnectionId: String? = null,
    val message: String? = null,
)

object PhoneWearProvisioningEvents {
    private val mutable = MutableSharedFlow<WearProvisioningResult>(replay = 1, extraBufferCapacity = 1)
    val events = mutable.asSharedFlow()

    fun receive(result: WearProvisioningResult) {
        mutable.tryEmit(result)
    }
}

@HiltViewModel
class WearProvisioningViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    private val sessions: WearLinkSessionClient,
) : ViewModel() {
    private val mutable = MutableStateFlow(WearProvisioningUiState())
    val state = mutable.asStateFlow()

    private fun requireWatchAccess() {
        val profiles = dagger.hilt.android.EntryPointAccessors.fromApplication(
            context.applicationContext,
            com.enve.app.profiles.ProfileActivityBinding.DeviceEntryPoint::class.java,
        ).profiles()
        check(!profiles.state.value.enabled && !profiles.state.value.locked && !profiles.state.value.switching) {
            "Watch linking is unavailable while family profiles are enabled."
        }
    }

    fun send(connection: ProviderConnection, password: String) {
        if (!supports(connection.source) || mutable.value.sendingConnectionId != null) return
        viewModelScope.launch {
            mutable.value = WearProvisioningUiState(sendingConnectionId = connection.id)
            val message = try {
                requireWatchAccess()
                provision(connection, password)
                "${connection.source.displayName} is ready on your watch."
            } catch (error: CancellationException) {
                throw error
            } catch (error: Exception) {
                error.message ?: "Couldn’t link the watch. Open Enve on the watch and try again."
            }
            mutable.value = WearProvisioningUiState(message = message)
        }
    }

    fun clearMessage() = mutable.update { it.copy(message = null) }

    private suspend fun provision(connection: ProviderConnection, password: String) = withContext(Dispatchers.IO) {
        require(connection.enabled) { "Turn this connection on before sending it to your watch." }
        require(!connection.needsReauth) { "Sign in to this connection again before sending it to your watch." }
        require(connection.customHeaders.isEmpty() && connection.serviceClientId.isBlank() && connection.serviceClientSecret.isBlank() && !connection.mtlsEnabled) {
            "This connection uses phone-only security settings and can’t be sent to the watch yet."
        }
        val nodes = Wearable.getNodeClient(context).connectedNodes.await()
        if (nodes.isEmpty()) error("No watch is connected. Open Enve on the watch and try again.")
        val requests = Wearable.getDataClient(context)
            .getDataItems(Uri.parse("wear://*${WearProtocol.PROVISIONING_REQUEST_PATH}"))
            .await()
            .let { buffer ->
                try {
                    buffer.mapNotNull { item ->
                        val data = item.data ?: return@mapNotNull null
                        val host = item.uri.host ?: return@mapNotNull null
                        runCatching { host to WearProtocol.decodeProvisioningRequest(data) }.getOrNull()
                    }
                } finally {
                    buffer.release()
                }
            }
        val nodeIds = nodes.mapTo(HashSet()) { it.id }
        val nearbyNodeIds = nodes.filterTo(HashSet()) { it.isNearby }.mapTo(HashSet()) { it.id }
        val freshRequests = requests.filter { System.currentTimeMillis() - it.second.createdAtMs in 0..REQUEST_LIFETIME_MS }
        val target = freshRequests.firstOrNull { it.first in nearbyNodeIds }
            ?: freshRequests.firstOrNull { it.first in nodeIds }
            ?: error("Open Enve on the watch, then try again.")
        requireWatchAccess()
        val session = sessions.create(connection, password)
        val payload = WearProvisionedConnection(
            connectionId = connection.id,
            source = connection.source.name,
            server = connection.serverUrl,
            username = connection.username,
            accessToken = session.accessToken,
            refreshToken = session.refreshToken,
        )
        val envelope = WearProvisioningCrypto.encrypt(
            target.second.publicKey,
            target.second.requestId,
            WearProtocol.encodeProvisionedConnection(payload),
        )
        requireWatchAccess()
        Wearable.getMessageClient(context).sendMessage(
            target.first,
            WearProtocol.PROVISION_CONNECTION_PATH,
            WearProtocol.encodeProvisioningEnvelope(envelope),
        ).await()
        val result = withTimeoutOrNull(15_000) {
            PhoneWearProvisioningEvents.events.first { it.requestId == target.second.requestId }
        } ?: error("The watch didn’t confirm the connection. Keep Enve open on the watch and try again.")
        if (!result.success) error(result.message ?: "The watch couldn’t save this connection. Try again.")
    }

    private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
        addOnSuccessListener { if (continuation.isActive) continuation.resume(it) }
        addOnFailureListener { if (continuation.isActive) continuation.resumeWithException(it) }
        addOnCanceledListener { continuation.cancel() }
    }

    companion object {
        private const val REQUEST_LIFETIME_MS = 5 * 60 * 1000L
        fun supports(source: BookSource): Boolean = source == BookSource.AUDIOBOOKSHELF || source == BookSource.GRIMMORY
    }
}
