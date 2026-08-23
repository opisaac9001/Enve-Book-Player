package com.enve.app.data.provider

import com.enve.app.data.smb.SmbCredentials
import com.enve.app.data.smb.SmbSourceService
import com.enve.core.data.local.ConnectionRegistry
import com.enve.core.auth.CredentialVault
import com.enve.core.data.local.PreferencesManager
import com.enve.core.data.model.AppMediaType
import com.enve.core.data.model.AudioTrack
import com.enve.core.data.model.Book
import com.enve.core.data.model.BookSource
import com.enve.core.data.model.Library
import com.enve.core.data.model.ProviderConnection
import com.enve.core.data.provider.ProviderAdapter
import com.enve.core.data.provider.ProviderPlaybackSession
import com.enve.core.data.provider.synthesizeChaptersFromTracks
import com.enve.core.data.remote.ConnectionScope
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class SmbProviderAdapter @Inject constructor(
    private val smbSourceService: SmbSourceService,
    private val connectionRegistry: ConnectionRegistry,
    private val vault: CredentialVault,
    private val prefs: PreferencesManager,
) : ProviderAdapter {
    override val source: BookSource = BookSource.SMB

    override suspend fun getLibraries(): Result<List<Library>> = runCatching {
        listOf(Library(id = "smb-root", name = "SMB Share", source = source))
    }

    override suspend fun getBooks(
        libraryId: String?,
        page: Int,
        size: Int,
        sort: String,
        dir: String,
    ): Result<List<Book>> = runCatching {
        val (connection, credentials) = scopedConnectionAndCredentials()
        smbSourceService.scan(connection.serverUrl, credentials, connection.id)
    }

    override suspend fun getContinueListening(): Result<List<Book>> = Result.success(emptyList())

    override suspend fun getContinueReading(): Result<List<Book>> = Result.success(emptyList())

    override suspend fun getRecentlyAdded(): Result<List<Book>> =
        getBooks("smb-root", 0, 50, "title", "asc")

    override suspend fun getAudioTracks(book: Book): Result<List<AudioTrack>> = runCatching {
        if (book.mediaType != AppMediaType.AUDIOBOOK) return@runCatching emptyList()
        val (connection, credentials) = scopedConnectionAndCredentials()
        val tracks = smbSourceService.scan(connection.serverUrl, credentials, connection.id)
            .firstOrNull { it.id == book.id }
            ?.audioTracks
            .orEmpty()
        tracks.map { track ->
            val smbUrl = track.contentUrl ?: track.fileId ?: return@map track
            track.copy(
                contentUrl = smbSourceService.localUrlFor(
                    smbUrl = smbUrl,
                    credentials = credentials,
                    fileName = track.fileName,
                ),
            )
        }
    }

    override suspend fun startPlaybackSession(book: Book): Result<ProviderPlaybackSession> = runCatching {
        val tracks = getAudioTracks(book).getOrThrow()
        ProviderPlaybackSession(
            sessionId = "smb-${book.id}",
            audioTracks = tracks,
            chapters = book.chapters.ifEmpty { synthesizeChaptersFromTracks(tracks, book.duration) },
        )
    }

    override suspend fun getEbookDownloadUrl(bookId: String): String? {
        val (_, credentials) = scopedConnectionAndCredentials()
        return smbSourceService.localUrlFor(
            smbUrl = bookId,
            credentials = credentials,
            fileName = bookId.substringAfterLast('/').ifBlank { "book.epub" },
        )
    }

    override fun invalidateCaches() = Unit

    private fun scopedConnectionAndCredentials(): Pair<ProviderConnection, SmbCredentials> {
        val scopedId = ConnectionScope.getConnectionId() ?: prefs.getActiveConnectionIdSync()
        val connection = connectionRegistry.getConnectionsSync().firstOrNull { it.id == scopedId }
            ?: error("No SMB connection selected")
        val username = vault.get(CredentialVault.usernameKey(connection.id)) ?: connection.username
        val password = vault.get(CredentialVault.passwordKey(connection.id))
            ?: vault.get(CredentialVault.accessTokenKey(connection.id))
            ?: prefs.getAccessTokenSync()
            ?: ""
        return connection to parseCredentials(username, password)
    }

    private fun parseCredentials(username: String, password: String): SmbCredentials {
        val domainSplit = username.split('\\', limit = 2)
        return if (domainSplit.size == 2) {
            SmbCredentials(username = domainSplit[1], password = password, domain = domainSplit[0])
        } else {
            SmbCredentials(username = username, password = password)
        }
    }
}
