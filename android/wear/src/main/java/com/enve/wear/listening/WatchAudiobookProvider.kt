package com.enve.wear.listening

import okhttp3.Response

enum class WatchSource(val displayName: String) {
    AUDIOBOOKSHELF("Audiobookshelf"),
    GRIMMORY("Grimmory"),
    STORYTELLER("Storyteller"),
    PLEX("Plex"),
    BOOKORBIT("BookOrbit"),
    SILO("Silo"),
    JELLYFIN("Jellyfin"),
    EMBY("Emby"),
    OPDS("OPDS"),
    LOCAL("Local files"),
}

data class WatchProviderCapabilities(
    val progress: Boolean = false,
)

data class WatchLibraryChoice(val id: String, val name: String)
data class WatchBookPage(val books: List<WatchBook>, val hasMore: Boolean)
data class WatchAudioFile(val url: String, val startMs: Long, val durationMs: Long)
data class WatchBookDownload(val book: WatchBook, val files: List<WatchAudioFile>)
data class WatchRemoteProgress(val positionMs: Long, val durationMs: Long, val updatedAt: Long)

interface WatchAudiobookProvider {
    val source: WatchSource
    val capabilities: WatchProviderCapabilities

    suspend fun libraries(account: WatchAccount): List<WatchLibraryChoice>
    suspend fun books(account: WatchAccount, libraryId: String, page: Int): WatchBookPage
    suspend fun download(account: WatchAccount, bookId: String): WatchBookDownload
    fun audio(account: WatchAccount, path: String, offset: Long, etag: String?): Response
    suspend fun fetchProgress(account: WatchAccount, bookId: String): WatchRemoteProgress?
    suspend fun pushProgress(account: WatchAccount, book: WatchBook, positionMs: Long)
}

class WatchProviderRegistry(private val vault: CredentialVault) {
    private val providers: Map<WatchSource, WatchAudiobookProvider> = listOf(
        WatchAbsClient(vault),
        WatchGrimmoryClient(vault),
    ).associateBy(WatchAudiobookProvider::source)

    fun provider(source: WatchSource): WatchAudiobookProvider = providers[source]
        ?: throw WatchRequestException("${source.displayName} is not available on the watch yet.")

    fun providerOrNull(source: WatchSource): WatchAudiobookProvider? = providers[source]

    fun provider(account: WatchAccount): WatchAudiobookProvider = provider(account.source)

    fun providerOrNull(account: WatchAccount): WatchAudiobookProvider? = providerOrNull(account.source)
}
