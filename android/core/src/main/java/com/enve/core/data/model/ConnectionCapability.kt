package com.enve.core.data.model

data class ConnectionCapability(
    val source: BookSource,
    val supportsUsernamePassword: Boolean = true,
    val supportsToken: Boolean = false,
    val supportsOidc: Boolean = false,
    val supportsQuickConnect: Boolean = false,
    val supportsWebLogin: Boolean = false,

    val credentialsOptional: Boolean = false,
    val supportsBrowserSignIn: Boolean = true,
    val supportsCustomHeaders: Boolean = true,
    val supportsServiceTokens: Boolean = true,
    val supportsMtls: Boolean = true,
    val supportsLibrarySelection: Boolean = false,
) {
    val hasMultipleAuthMethods: Boolean
        get() = listOf(supportsUsernamePassword, supportsToken, supportsOidc, supportsQuickConnect, supportsWebLogin).count { it } > 1

    val hasAdvancedOptions: Boolean
        get() = supportsBrowserSignIn || supportsCustomHeaders || supportsServiceTokens || supportsMtls

    companion object {
        private val matrix: Map<BookSource, ConnectionCapability> = mapOf(
            BookSource.GRIMMORY to ConnectionCapability(
                source = BookSource.GRIMMORY,
                supportsOidc = true,
            ),
            BookSource.STORYTELLER to ConnectionCapability(
                source = BookSource.STORYTELLER,
                supportsWebLogin = true,
            ),
            BookSource.AUDIOBOOKSHELF to ConnectionCapability(
                source = BookSource.AUDIOBOOKSHELF,
                supportsOidc = true,
                supportsLibrarySelection = true,
            ),
            BookSource.JELLYFIN to ConnectionCapability(
                source = BookSource.JELLYFIN,
                supportsQuickConnect = true,
                supportsLibrarySelection = true,
            ),
            BookSource.EMBY to ConnectionCapability(
                source = BookSource.EMBY,
                supportsLibrarySelection = true,
            ),
            BookSource.PLEX to ConnectionCapability(
                source = BookSource.PLEX,
                supportsUsernamePassword = false,
                supportsToken = true,
                supportsBrowserSignIn = false,
                supportsCustomHeaders = false,
                supportsServiceTokens = false,
                supportsMtls = false,
            ),
            BookSource.KOMGA to ConnectionCapability(
                source = BookSource.KOMGA,
                supportsToken = true,
                supportsOidc = true,
            ),
            BookSource.KAVITA to ConnectionCapability(
                source = BookSource.KAVITA,
                supportsToken = true,
            ),
            BookSource.BOOKORBIT to ConnectionCapability(
                source = BookSource.BOOKORBIT,
                supportsOidc = true,
            ),
            BookSource.SILO to ConnectionCapability(
                source = BookSource.SILO,
                supportsToken = true,
            ),
            BookSource.OPDS to ConnectionCapability(
                source = BookSource.OPDS,
                supportsToken = true,
                credentialsOptional = true,
            ),
            BookSource.WEBDAV to ConnectionCapability(
                source = BookSource.WEBDAV,
                supportsToken = true,
            ),
            BookSource.TORBOX to ConnectionCapability(
                source = BookSource.TORBOX,
                supportsUsernamePassword = false,
                supportsToken = true,
                supportsBrowserSignIn = false,
                supportsCustomHeaders = false,
                supportsServiceTokens = false,
                supportsMtls = false,
                supportsLibrarySelection = true,
            ),
            BookSource.PREMIUMIZE to ConnectionCapability(
                source = BookSource.PREMIUMIZE,
                supportsUsernamePassword = false,
                supportsToken = true,
                supportsBrowserSignIn = false,
                supportsCustomHeaders = false,
                supportsServiceTokens = false,
                supportsMtls = false,
            ),
            BookSource.REALDEBRID to ConnectionCapability(
                source = BookSource.REALDEBRID,
                supportsUsernamePassword = false,
                supportsToken = true,
                supportsBrowserSignIn = false,
                supportsCustomHeaders = false,
                supportsServiceTokens = false,
                supportsMtls = false,
            ),
            BookSource.SMB to ConnectionCapability(
                source = BookSource.SMB,
                supportsBrowserSignIn = false,
                supportsServiceTokens = false,
                supportsMtls = false,
            ),
            BookSource.LOCAL to ConnectionCapability(
                source = BookSource.LOCAL,
                supportsUsernamePassword = false,
                supportsToken = false,
                supportsBrowserSignIn = false,
                supportsCustomHeaders = false,
                supportsServiceTokens = false,
                supportsMtls = false,
            ),
        )

        fun forSource(source: BookSource): ConnectionCapability =
            matrix[source] ?: ConnectionCapability(source)
    }
}
