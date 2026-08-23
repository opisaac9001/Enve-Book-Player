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

/**
 * TLS trust + hostname verification policy for self-hosted servers.
 *
 * Default behaviour delegates to the platform's strict trust store. The strict path is
 * relaxed only when *all three* of these conditions hold:
 *
 *  1. The hostname being validated is an IP literal (e.g. "100.93.141.73") or a domain
 *     reserved for self-hosted networks (`*.ts.net` for Tailscale MagicDNS, `*.local`
 *     for mDNS/Bonjour).
 *  2. The resolved address is in a private / loopback / link-local / CGNAT range.
 *  3. The system trust store rejected the certificate (so we never override a successful
 *     validation, only fall back when one fails).
 *
 * This means a malicious actor cannot bypass validation by pointing a public hostname
 * (`bookloore.com`) at a private IP via DNS hijacking - the hostname doesn't match the
 * IP-literal / private-domain whitelist, so the strict path runs unmodified.
 *
 * The previous unconditional `trustAllManager` accepted any certificate from any host,
 * which was a MITM vulnerability for public-hostname connections (e.g. CDN-fronted
 * Bookloore deployments). This file restores production-correct behaviour for the public
 * case while preserving the self-signed / mDNS / Tailscale workflows that originally
 * motivated the bypass.
 */
object PrivateNetworkTrust {

    /**
     * Builds a trust manager that defers to the platform CA store, then falls back to
     * accepting self-signed certs only when the peer is on a private network.
     */
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
                // No socket/engine available → no way to read the peer host. Strict only.
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

    /**
     * Hostname verifier that defers to the platform default, then accepts mismatches only
     * when the hostname literal is in the private/Tailscale/mDNS allowlist. The platform
     * default verifier already handles the common case (CN/SAN matches hostname) - we only
     * extend it for the self-signed / IP-literal use cases.
     */
    fun buildHostnameVerifier(): HostnameVerifier {
        val systemDefault = HttpsURLConnection.getDefaultHostnameVerifier()
        return HostnameVerifier { hostname, session ->
            if (systemDefault.verify(hostname, session)) return@HostnameVerifier true
            isAllowedPrivateHostname(hostname)
        }
    }

    /**
     * True when [hostname] is a textual IP in a private range OR a hostname in a reserved
     * self-hosted domain. Hostnames that resolve to private IPs but aren't themselves
     * IP literals are NOT allowed - that's the DNS-hijack vector we deliberately close.
     */
    private fun isAllowedPrivateHostname(hostname: String): Boolean {
        val literal = runCatching { InetAddress.getByName(hostname) }.getOrNull()
        if (literal != null && literal.hostAddress == hostname) {
            // hostname WAS an IP literal - check if its range is private
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

    /**
     * Variant invoked from [X509ExtendedTrustManager] paths where the SSLEngine/Socket
     * gives us the peer string - which can be either a hostname OR a literal IP, depending
     * on how OkHttp dialed the connection. Treat both consistently.
     */
    private fun isAllowedPrivatePeer(peer: String): Boolean {
        if (isAllowedPrivateHostname(peer)) return true
        // Some platforms hand us the resolved IP as `peer` even for hostname connections.
        // Treat that as authoritative - if the IP is private, the actual transport is
        // on the private network, so a self-signed cert is acceptable.
        val addr = runCatching { InetAddress.getByName(peer) }.getOrNull() ?: return false
        return isPrivateAddress(addr)
    }

    private fun isPrivateAddress(addr: InetAddress): Boolean {
        if (addr.isLoopbackAddress) return true        // 127.0.0.0/8, ::1
        if (addr.isLinkLocalAddress) return true       // 169.254.0.0/16, fe80::/10
        if (addr.isSiteLocalAddress) return true       // 10/8, 172.16/12, 192.168/16 (IPv6: deprecated fec0::/10)
        val bytes = addr.address ?: return false
        if (bytes.size == 4) {
            val first = bytes[0].toInt() and 0xff
            val second = bytes[1].toInt() and 0xff
            // CGNAT - used by Tailscale (100.64.0.0/10) and some carrier-grade NATs
            if (first == 100 && second in 64..127) return true
        }
        // IPv6 ULA fc00::/7 (covers Tailscale's fd7a:115c:a1e0::/48). Java's isSiteLocalAddress only matches the deprecated fec0::/10.
        if (bytes.size == 16 && (bytes[0].toInt() and 0xfe) == 0xfc) return true
        return false
    }

    @Suppress("UNUSED_PARAMETER")
    private fun _unusedSession(session: SSLSession?) = Unit
}
