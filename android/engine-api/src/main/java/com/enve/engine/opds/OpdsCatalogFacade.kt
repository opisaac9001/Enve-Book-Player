package com.enve.engine.opds

import com.enve.core.data.model.Book
import kotlinx.coroutines.flow.Flow

data class OpdsBrowseEntry(
    val title: String,
    val href: String,
    val count: Int? = null,
    val isActive: Boolean = false,
    val isWebCatalog: Boolean = false,
)

data class OpdsFacetGroupState(
    val title: String,
    val facets: List<OpdsBrowseEntry>,
)

data class OpdsShelfState(
    val title: String,
    val moreHref: String?,
    val books: List<Book>,
    val navigation: List<OpdsBrowseEntry>,
)

data class OpdsSearchState(
    val href: String,
    val templated: Boolean,
    val title: String?,
    val type: String = "",
)

data class OpdsPaginationState(
    val nextUrl: String? = null,
    val previousUrl: String? = null,
    val firstUrl: String? = null,
    val lastUrl: String? = null,
    val totalResults: Int? = null,
    val currentPage: Int? = null,
    val truncated: Boolean = false,
)

data class OpdsCatalogPage(
    val url: String,
    val title: String?,
    val navigation: List<OpdsBrowseEntry> = emptyList(),
    val shelves: List<OpdsShelfState> = emptyList(),
    val facetGroups: List<OpdsFacetGroupState> = emptyList(),
    val books: List<Book> = emptyList(),
    val search: OpdsSearchState? = null,
    val pagination: OpdsPaginationState = OpdsPaginationState(),
    val singlePublication: Book? = null,
) {
    val isEmpty: Boolean
        get() = navigation.isEmpty() && shelves.isEmpty() && books.isEmpty() && singlePublication == null
}

enum class OpdsAuthMethodKind { BASIC, OAUTH_PASSWORD, OAUTH_IMPLICIT, UNSUPPORTED }

data class OpdsAuthMethodState(
    val kind: OpdsAuthMethodKind,
    val type: String,
    val loginLabel: String?,
    val passwordLabel: String?,
    val authorizeUrl: String?,
)

data class OpdsAuthChallenge(
    val url: String,
    val title: String?,
    val description: String?,
    val helpUrls: List<String>,
    val methods: List<OpdsAuthMethodState>,
)

sealed interface OpdsCatalogResult {
    data class Loaded(val page: OpdsCatalogPage) : OpdsCatalogResult

    data class AuthenticationRequired(val challenge: OpdsAuthChallenge) : OpdsCatalogResult

    data class Failed(val message: String) : OpdsCatalogResult
}

enum class OpdsAcquisitionAction { OPEN, SAMPLE, BORROW, BUY, SUBSCRIBE, UNSUPPORTED }

data class OpdsAvailabilityState(
    val state: String? = null,
    val until: String? = null,
    val copiesTotal: Int? = null,
    val copiesAvailable: Int? = null,
    val holdsTotal: Int? = null,
    val holdPosition: Int? = null,
)

data class OpdsAcquisitionOption(
    val action: OpdsAcquisitionAction,
    val href: String,
    val label: String,
    val formatLabel: String?,
    val priceLabel: String? = null,
    val availability: OpdsAvailabilityState? = null,
    val unsupportedReason: String? = null,
) {
    val isActionable: Boolean get() = unsupportedReason == null
}

sealed interface OpdsSignInResult {
    data object Succeeded : OpdsSignInResult

    data class RedirectRequired(val authorizeUrl: String) : OpdsSignInResult

    data class Failed(val message: String) : OpdsSignInResult
}

interface OpdsCatalogFacade {
    val progressionAuthChallenge: Flow<OpdsAuthChallenge?>

    val signedIn: Flow<String>

    val signInFailed: Flow<String>

    suspend fun root(connectionId: String): OpdsCatalogResult

    suspend fun open(connectionId: String, url: String): OpdsCatalogResult

    suspend fun search(connectionId: String, search: OpdsSearchState, query: String): OpdsCatalogResult

    suspend fun acquisitions(connectionId: String, bookId: String): List<OpdsAcquisitionOption>

    suspend fun selectAcquisition(connectionId: String, bookId: String, href: String): Book?

    suspend fun signIn(
        connectionId: String,
        method: OpdsAuthMethodState,
        username: String,
        password: String,
    ): OpdsSignInResult

    suspend fun completeImplicitSignIn(
        connectionId: String,
        method: OpdsAuthMethodState,
        redirectUrl: String,
        state: String,
    ): OpdsSignInResult

    suspend fun signOut(connectionId: String)

    fun dismissProgressionAuthChallenge()
}
