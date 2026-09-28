// AGENT-LOCKED
package com.enve.core.data.remote.security

import java.net.InetAddress
import java.net.Socket
import java.security.KeyStore
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSession
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509ExtendedTrustManager
import javax.net.ssl.X509TrustManager

object PrivateNetworkTrust {

    fun buildTrustManager(): X509TrustManager {
        val tmf = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        tmf.init(null as KeyStore?)
        val systemDefault = tmf.trustManagers
            .filterIsInstance<X509ExtendedTrustManager>()
            .firstOrNull()
            ?: error("No X509ExtendedTrustManager in platform default trust managers")

        return object : X509ExtendedTrustManager() {

            override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String) =
                systemDefault.checkClientTrusted(chain, authType)

            override fun checkClientTrusted(
                chain: Array<out X509Certificate>,
                authType: String,
                socket: Socket?,
            ) = systemDefault.checkClientTrusted(chain, authType, socket)

            override fun checkClientTrusted(
                chain: Array<out X509Certificate>,
                authType: String,
                engine: SSLEngine?,
            ) = systemDefault.checkClientTrusted(chain, authType, engine)

            override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String) {
                systemDefault.checkServerTrusted(chain, authType)
            }

            override fun checkServerTrusted(
                chain: Array<out X509Certificate>,
                authType: String,
                socket: Socket?,
            ) {
                try {
                    systemDefault.checkServerTrusted(chain, authType, socket)
                } catch (e: CertificateException) {
                    val peer = (socket?.inetAddress)?.hostAddress
                    if (peer == null || !isAllowedPrivatePeer(peer)) throw e
                }
            }

            override fun checkServerTrusted(
                chain: Array<out X509Certificate>,
                authType: String,
                engine: SSLEngine?,
            ) {
                try {
                    systemDefault.checkServerTrusted(chain, authType, engine)
                } catch (e: CertificateException) {
                    val peer = engine?.peerHost
                    if (peer == null || !isAllowedPrivatePeer(peer)) throw e
                }
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = systemDefault.acceptedIssuers
        }
    }

    fun buildHostnameVerifier(): HostnameVerifier {
        val systemDefault = HttpsURLConnection.getDefaultHostnameVerifier()
        return HostnameVerifier { hostname, session ->
            if (systemDefault.verify(hostname, session)) return@HostnameVerifier true
            isAllowedPrivateHostname(hostname)
        }
    }

    private fun isAllowedPrivateHostname(hostname: String): Boolean {
        val literal = runCatching { InetAddress.getByName(hostname) }.getOrNull()
        if (literal != null && literal.hostAddress == hostname) {
            return isPrivateAddress(literal)
        }
        val lower = hostname.lowercase()
        return lower.endsWith(".ts.net") ||
            lower.endsWith(".local") ||
            lower.endsWith(".lan") ||
            lower.endsWith(".home") ||
            lower.endsWith(".internal") ||
            lower.endsWith(".plex.direct")
    }

    private fun isAllowedPrivatePeer(peer: String): Boolean {
        if (isAllowedPrivateHostname(peer)) return true
        val addr = runCatching { InetAddress.getByName(peer) }.getOrNull() ?: return false
        return isPrivateAddress(addr)
    }

    private fun isPrivateAddress(addr: InetAddress): Boolean {
        if (addr.isLoopbackAddress) return true
        if (addr.isLinkLocalAddress) return true
        if (addr.isSiteLocalAddress) return true
        val bytes = addr.address ?: return false
        if (bytes.size == 4) {
            val first = bytes[0].toInt() and 0xff
            val second = bytes[1].toInt() and 0xff
            if (first == 100 && second in 64..127) return true
        }
        if (bytes.size == 16 && (bytes[0].toInt() and 0xfe) == 0xfc) return true
        return false
    }

    @Suppress("UNUSED_PARAMETER")
    private fun _unusedSession(session: SSLSession?) = Unit
}
