package com.enve.wear

import android.content.Context
import android.net.Uri
import com.enve.wear.protocol.WearProtocol
import com.enve.wear.protocol.WearState
import com.google.android.gms.wearable.DataClient
import com.google.android.gms.wearable.DataEvent
import com.google.android.gms.wearable.DataEventBuffer
import com.google.android.gms.wearable.Wearable

class WearConnection(
    context: Context,
    private val onState: (WearState) -> Unit,
    private val onAvailability: (Boolean) -> Unit,
) : DataClient.OnDataChangedListener {
    private val dataClient = Wearable.getDataClient(context)
    private val messageClient = Wearable.getMessageClient(context)
    private val nodeClient = Wearable.getNodeClient(context)

    fun start() {
        dataClient.addListener(this)
        dataClient.getDataItems(Uri.parse("wear://*${WearProtocol.STATE_PATH}"))
            .addOnSuccessListener { buffer ->
                try {
                    buffer.firstOrNull()?.data?.let(::decode)
                } finally {
                    buffer.release()
                }
            }
        send(WearProtocol.REQUEST_STATE_PATH)
    }

    fun stop() {
        dataClient.removeListener(this)
    }

    fun send(path: String, payload: ByteArray = byteArrayOf()) {
        nodeClient.connectedNodes
            .addOnSuccessListener { nodes ->
                onAvailability(nodes.isNotEmpty())
                nodes.forEach { node -> messageClient.sendMessage(node.id, path, payload) }
            }
            .addOnFailureListener { onAvailability(false) }
    }

    override fun onDataChanged(events: DataEventBuffer) {
        events.forEach { event ->
            if (event.type == DataEvent.TYPE_CHANGED && event.dataItem.uri.path == WearProtocol.STATE_PATH) {
                event.dataItem.data?.let(::decode)
            }
        }
    }

    private fun decode(bytes: ByteArray) {
        runCatching { WearProtocol.decode(bytes) }.onSuccess(onState)
    }
}
