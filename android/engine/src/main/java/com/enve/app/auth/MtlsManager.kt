// AGENT-LOCKED
package com.enve.app.auth

import android.util.Base64
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import java.io.ByteArrayInputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.net.URI
import java.security.KeyStore
import java.security.Principal
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.X509KeyManager

@Singleton
class MtlsManager @Inject constructor(
    private val vault: CredentialVault,
    private val connectionRegistry: ConnectionRegistry,
) {
    private val keyManagerCache = ConcurrentHashMap<String, X509KeyManager?>()

    fun validateAndStore(connectionId: String, certBytes: ByteArray, password: String): String {
        val ks = loadKeyStore(certBytes, password)
        val alias = ks.aliases().toList().firstOrNull()
            ?: throw IllegalArgumentException("No certificate found in the file")
        val cert = ks.getCertificate(alias) as X509Certificate
        val subject = cert.subjectDN.name

        vault.put(CredentialVault.mtlsCertKey(connectionId), Base64.encodeToString(certBytes, Base64.NO_WRAP))
        vault.put(CredentialVault.mtlsCertPasswordKey(connectionId), password)
        keyManagerCache.remove(connectionId)

        return subject
    }

    fun validateOnly(certBytes: ByteArray, password: String): String {
        val ks = loadKeyStore(certBytes, password)
        val alias = ks.aliases().toList().firstOrNull()
            ?: throw IllegalArgumentException("No certificate found in the file")
        return (ks.getCertificate(alias) as X509Certificate).subjectDN.name
    }

    fun clearCert(connectionId: String) {
        vault.remove(CredentialVault.mtlsCertKey(connectionId))
        vault.remove(CredentialVault.mtlsCertPasswordKey(connectionId))
        keyManagerCache.remove(connectionId)
    }

    fun hasCert(connectionId: String): Boolean =
        vault.get(CredentialVault.mtlsCertKey(connectionId)) != null

    fun getCertSubject(connectionId: String): String? {
        val b64 = vault.get(CredentialVault.mtlsCertKey(connectionId)) ?: return null
        val password = vault.get(CredentialVault.mtlsCertPasswordKey(connectionId)) ?: ""
        return runCatching {
            val ks = loadKeyStore(Base64.decode(b64, Base64.NO_WRAP), password)
            val alias = ks.aliases().toList().firstOrNull() ?: return null
            (ks.getCertificate(alias) as? X509Certificate)?.subjectDN?.name
        }.getOrNull()
    }

    fun invalidateCacheFor(connectionId: String) {
        keyManagerCache.remove(connectionId)
    }

    fun buildKeyManager(): DynamicKeyManager = DynamicKeyManager(this, connectionRegistry)

    internal fun keyManagerForConnection(connectionId: String): X509KeyManager? {
        return keyManagerCache.getOrPut(connectionId) {
            val b64 = vault.get(CredentialVault.mtlsCertKey(connectionId)) ?: return@getOrPut null
            val password = vault.get(CredentialVault.mtlsCertPasswordKey(connectionId)) ?: ""
            runCatching {
                val ks = loadKeyStore(Base64.decode(b64, Base64.NO_WRAP), password)
                val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
                kmf.init(ks, password.toCharArray())
                kmf.keyManagers.filterIsInstance<X509KeyManager>().firstOrNull()
            }.getOrNull()
        }
    }

    private fun loadKeyStore(certBytes: ByteArray, password: String): KeyStore {
        val ks = KeyStore.getInstance("PKCS12")
        ks.load(ByteArrayInputStream(certBytes), password.toCharArray())
        return ks
    }
}

class DynamicKeyManager(
    private val mtlsManager: MtlsManager,
    private val connectionRegistry: ConnectionRegistry,
) : X509KeyManager {

    override fun chooseClientAlias(
        keyType: Array<String>,
        issuers: Array<Principal>?,
        socket: Socket?,
    ): String? {
        val host = (socket?.remoteSocketAddress as? InetSocketAddress)?.hostName ?: return null
        val connections = connectionRegistry.getConnectionsSync()
        return connections.find { conn ->
            conn.mtlsEnabled && mtlsManager.hasCert(conn.id) &&
                runCatching { URI(conn.serverUrl).host.equals(host, ignoreCase = true) }.getOrDefault(false)
        }?.id
    }

    override fun getCertificateChain(alias: String): Array<X509Certificate>? {
        val km = mtlsManager.keyManagerForConnection(alias) ?: return null
        val realAlias = (km.getClientAliases("RSA", null) ?: km.getClientAliases("EC", null))
            ?.firstOrNull() ?: return null
        return km.getCertificateChain(realAlias)
    }

    override fun getPrivateKey(alias: String): PrivateKey? {
        val km = mtlsManager.keyManagerForConnection(alias) ?: return null
        val realAlias = (km.getClientAliases("RSA", null) ?: km.getClientAliases("EC", null))
            ?.firstOrNull() ?: return null
        return km.getPrivateKey(realAlias)
    }

    override fun getClientAliases(keyType: String?, issuers: Array<Principal>?): Array<String>? = null
    override fun getServerAliases(keyType: String?, issuers: Array<Principal>?): Array<String>? = null
    override fun chooseServerAlias(keyType: String?, issuers: Array<Principal>?, socket: Socket?): String? = null
}
