package com.enve.app.playback

import android.net.Uri
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener

internal const val PUBLIC_STREAM_FRAGMENT = "enve-public-stream"

internal fun publicStreamUrl(url: String): String = "$url#$PUBLIC_STREAM_FRAGMENT"

@UnstableApi
internal class PublicStreamRoutingDataSource(
    private val authenticated: DataSource,
    private val public: DataSource,
) : DataSource {
    private var active: DataSource? = null

    override fun addTransferListener(transferListener: TransferListener) {
        authenticated.addTransferListener(transferListener)
        public.addTransferListener(transferListener)
    }

    override fun open(dataSpec: DataSpec): Long {
        if (dataSpec.uri.fragment == PUBLIC_STREAM_FRAGMENT) {
            active = public
            return public.open(dataSpec)
        }
        active = authenticated
        val connectionId = streamConnectionId(dataSpec.uri.encodedFragment)
            ?: return authenticated.open(dataSpec)
        return authenticated.open(
            dataSpec.buildUpon()
                .setUri(dataSpec.uri.buildUpon().encodedFragment(null).build())
                .setHttpRequestHeaders(dataSpec.httpRequestHeaders + (STREAM_CONNECTION_HEADER to connectionId))
                .build(),
        )
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int =
        checkNotNull(active).read(buffer, offset, length)

    override fun getUri(): Uri? = active?.uri

    override fun getResponseHeaders(): Map<String, List<String>> = active?.responseHeaders.orEmpty()

    override fun close() {
        active?.close()
        active = null
    }
}
