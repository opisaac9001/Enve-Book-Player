package com.enve.app.hearth

import com.enve.app.data.opds.OpdsAcquisitionStore
import com.enve.app.data.opds.OpdsAuthenticationDocument
import com.enve.app.data.opds.OpdsAuthenticationFlow
import com.enve.app.data.opds.OpdsAuthenticationMethod
import com.enve.app.data.opds.OpdsAuthenticationRequiredException
import com.enve.app.data.opds.OpdsAuthenticationService
import com.enve.app.data.opds.OPEN_SEARCH_MEDIA_TYPE
import com.enve.app.data.opds.OpdsLoginResult
import com.enve.app.data.opds.OpdsProgressionService
import com.enve.app.data.opds.expandOpdsSearchTemplate
import com.enve.app.data.opds.isOpenSearchDescription
import com.enve.app.data.opds.parseOpdsImplicitCallback
import com.enve.app.data.opds.parseOpenSearchTemplate
import com.enve.app.data.repository.OpdsAcquisition
import com.enve.app.data.repository.OpdsAcquisitionKind
import com.enve.app.data.repository.OpdsDrm
import com.enve.app.data.repository.OpdsFacet
import com.enve.app.data.repository.OpdsFeedParser
import com.enve.app.data.repository.OpdsFormat
import com.enve.app.data.repository.OpdsRepository
import com.enve.app.data.repository.OpdsSearchLink
import com.enve.app.data.repository.isReadableContent
import com.enve.app.data.repository.isHttpUrl
import com.enve.app.data.repository.isSameOpdsOrigin
import com.enve.app.data.repository.toOpdsBook
import com.enve.core.data.local.BookCacheDao
import com.enve.core.data.local.toBook
import com.enve.core.data.model.Book
import com.enve.core.data.util.runSuspendCatching
import com.enve.engine.opds.OpdsAcquisitionAction
import com.enve.engine.opds.OpdsAcquisitionOption
import com.enve.engine.opds.OpdsAuthChallenge
import com.enve.engine.opds.OpdsAuthMethodKind
import com.enve.engine.opds.OpdsAuthMethodState
import com.enve.engine.opds.OpdsAvailabilityState
import com.enve.engine.opds.OpdsBrowseEntry
import com.enve.engine.opds.OpdsCatalogFacade
import com.enve.engine.opds.OpdsCatalogPage
import com.enve.engine.opds.OpdsCatalogResult
import com.enve.engine.opds.OpdsFacetGroupState
import com.enve.engine.opds.OpdsPaginationState
import com.enve.engine.opds.OpdsSearchState
import com.enve.engine.opds.OpdsShelfState
import com.enve.engine.opds.OpdsSignInResult
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.map
import java.util.Currency
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class OpdsCatalogFacadeImpl @Inject constructor(
    private val repository: OpdsRepository,
    private val acquisitionStore: OpdsAcquisitionStore,
    private val authentication: OpdsAuthenticationService,
    private val progression: OpdsProgressionService,
    private val bookCache: BookCacheDao,
) : OpdsCatalogFacade {

    private val _signedIn = MutableSharedFlow<String>(extraBufferCapacity = 1)
    override val signedIn: Flow<String> = _signedIn.asSharedFlow()

    private val _signInFailed = MutableSharedFlow<String>(extraBufferCapacity = 1)
    override val signInFailed: Flow<String> = _signInFailed.asSharedFlow()

    private val discoveredChallenges = ConcurrentHashMap<String, OpdsAuthChallenge>()

    override val progressionAuthChallenge: Flow<OpdsAuthChallenge?> =
        progression.authenticationPrompt.map { prompt ->
            val url = prompt?.authenticateUrl ?: return@map null
            discoveredChallenges[url] ?: run {
                val document = runSuspendCatching { authentication.discover(url) }.getOrNull()
                document?.toChallenge(url)?.also { discoveredChallenges[url] = it }
                    ?: OpdsAuthChallenge(url, prompt.bookTitle, null, emptyList(), emptyList())
            }
        }

    override suspend fun root(connectionId: String): OpdsCatalogResult {
        val url = repository.getRootCatalogUrl(connectionId)
            ?: return OpdsCatalogResult.Failed("This source has no catalog URL")
        return open(connectionId, url)
    }

    override suspend fun open(connectionId: String, url: String): OpdsCatalogResult =
        repository.getPage(connectionId, url).fold(
            onSuccess = { OpdsCatalogResult.Loaded(it.toCatalogPage(url)) },
            onFailure = ::toFailure,
        )

    override suspend fun search(
        connectionId: String,
        search: OpdsSearchState,
        query: String,
    ): OpdsCatalogResult {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return open(connectionId, search.href)
        val template = resolveSearchTemplate(connectionId, search)
            ?: return OpdsCatalogResult.Failed("This catalog did not describe how to search it")
        return open(connectionId, expandOpdsSearchTemplate(template, trimmed))
    }

    override suspend fun acquisitions(connectionId: String, bookId: String): List<OpdsAcquisitionOption> =
        acquisitionStore.acquisitions(connectionId, bookId).map { it.toOption() }

    override suspend fun selectAcquisition(connectionId: String, bookId: String, href: String): Book? {
        val stored = acquisitionStore.acquisitions(connectionId, bookId)
        acceptableOpdsAcquisition(stored, href, repository.getRootCatalogUrl(connectionId)) ?: return null
        if (bookCache.setOpdsAcquisitionUrl(bookId, connectionId, href) == 0) return null
        return bookCache.getByIdAndConnection(bookId, connectionId)?.toBook()
    }

    override suspend fun signIn(
        connectionId: String,
        method: OpdsAuthMethodState,
        username: String,
        password: String,
    ): OpdsSignInResult =
        authentication.signIn(connectionId, method.toMethod(), username, password)
            .toSignInResult()
            .alsoOnSuccess(connectionId)

    override suspend fun completeImplicitSignIn(
        connectionId: String,
        method: OpdsAuthMethodState,
        redirectUrl: String,
        state: String,
    ): OpdsSignInResult {
        val callback = parseOpdsImplicitCallback(redirectUrl, state)
            ?: return OpdsSignInResult.Failed("The sign-in page did not return a usable token")
                .alsoOnFailure()
        return authentication.completeImplicit(connectionId, method.toMethod(), callback)
            .toSignInResult()
            .alsoOnSuccess(connectionId)
            .alsoOnFailure()
    }

    override suspend fun signOut(connectionId: String) {
        authentication.signOut(connectionId)
        repository.invalidateCaches(connectionId)
    }

    override fun dismissProgressionAuthChallenge() = progression.dismissAuthenticationPrompt()

    private suspend fun resolveSearchTemplate(connectionId: String, search: OpdsSearchState): String? {
        if (search.templated) return search.href
        if (!isOpenSearchDescription(search.type)) return null
        val document = repository.getDocument(connectionId, search.href, OPEN_SEARCH_MEDIA_TYPE).getOrNull()
            ?: return null
        return parseOpenSearchTemplate(document.payload, document.url)
    }

    private fun toFailure(error: Throwable): OpdsCatalogResult = when (error) {
        is OpdsAuthenticationRequiredException -> OpdsCatalogResult.AuthenticationRequired(
            error.document?.toChallenge(error.url)
                ?: OpdsAuthChallenge(error.url, null, null, emptyList(), emptyList()),
        )

        else -> OpdsCatalogResult.Failed(error.message ?: "The catalog could not be loaded")
    }

    private fun OpdsRepository.OpdsPage.toCatalogPage(url: String): OpdsCatalogPage {
        val groupedIds = groups.flatMap { group -> group.publications.map { it.id } }.toSet()
        val loose = publications.filterNot { groupedIds.contains(it.id) }
        val single = loose.singleOrNull()?.takeIf { isSinglePublicationDocument }
        return OpdsCatalogPage(
            url = url,
            title = title,
            navigation = navigationLinks.map { it.toBrowseEntry() },
            shelves = groups.map { group ->
                OpdsShelfState(
                    title = group.title,
                    moreHref = group.selfUrl,
                    books = group.publications.map { it.summary.toOpdsBook() },
                    navigation = group.navigationLinks.map { it.toBrowseEntry() },
                )
            },
            facetGroups = facets.groupBy { it.groupTitle }.map { (groupTitle, entries) ->
                OpdsFacetGroupState(title = groupTitle, facets = entries.map { it.toEntry() })
            },
            books = if (single != null) emptyList() else loose.map { it.summary.toOpdsBook() },
            search = searchLinks.firstOrNull()?.toSearchState(),
            pagination = OpdsPaginationState(
                nextUrl = nextUrl,
                previousUrl = previousUrl,
                firstUrl = firstUrl,
                lastUrl = lastUrl,
                totalResults = totalResults,
                currentPage = currentPage,
                truncated = truncated,
            ),
            singlePublication = single?.summary?.toOpdsBook(),
        )
    }

    private fun OpdsFeedParser.NavigationLink.toBrowseEntry() =
        OpdsBrowseEntry(
            title = title,
            href = href,
            count = numberOfItems,
            isWebCatalog = OpdsFeedParser.isWebCatalogType(type) && isHttpUrl(href),
        )

    private fun OpdsFacet.toEntry() =
        OpdsBrowseEntry(title = title, href = href, count = numberOfItems, isActive = isActive)

    private fun OpdsSearchLink.toSearchState() =
        OpdsSearchState(href = href, templated = templated, title = title, type = type)

    private fun OpdsAuthenticationDocument.toChallenge(url: String) = OpdsAuthChallenge(
        url = url,
        title = title,
        description = description,
        helpUrls = helpUrls,
        methods = methods.map {
            OpdsAuthMethodState(
                kind = it.flow.toKind(),
                type = it.type,
                loginLabel = it.labels.login,
                passwordLabel = it.labels.password,
                authorizeUrl = it.authenticateUrl,
            )
        },
    )

    private fun OpdsAuthenticationFlow.toKind() = when (this) {
        OpdsAuthenticationFlow.BASIC -> OpdsAuthMethodKind.BASIC
        OpdsAuthenticationFlow.OAUTH_PASSWORD -> OpdsAuthMethodKind.OAUTH_PASSWORD
        OpdsAuthenticationFlow.OAUTH_IMPLICIT -> OpdsAuthMethodKind.OAUTH_IMPLICIT
        OpdsAuthenticationFlow.UNSUPPORTED -> OpdsAuthMethodKind.UNSUPPORTED
    }

    private fun OpdsAuthMethodState.toMethod() = OpdsAuthenticationMethod(
        type = type,
        flow = when (kind) {
            OpdsAuthMethodKind.BASIC -> OpdsAuthenticationFlow.BASIC
            OpdsAuthMethodKind.OAUTH_PASSWORD -> OpdsAuthenticationFlow.OAUTH_PASSWORD
            OpdsAuthMethodKind.OAUTH_IMPLICIT -> OpdsAuthenticationFlow.OAUTH_IMPLICIT
            OpdsAuthMethodKind.UNSUPPORTED -> OpdsAuthenticationFlow.UNSUPPORTED
        },
        authenticateUrl = authorizeUrl,
    )

    private fun OpdsSignInResult.alsoOnFailure(): OpdsSignInResult = also {
        if (it is OpdsSignInResult.Failed) _signInFailed.tryEmit(it.message)
    }

    private fun OpdsSignInResult.alsoOnSuccess(connectionId: String): OpdsSignInResult = also {
        if (it is OpdsSignInResult.Succeeded) {
            repository.invalidateCaches(connectionId)
            progression.dismissAuthenticationPrompt()
            _signedIn.tryEmit(connectionId)
        }
    }

    private fun OpdsLoginResult.toSignInResult(): OpdsSignInResult = when (this) {
        OpdsLoginResult.Succeeded -> OpdsSignInResult.Succeeded
        is OpdsLoginResult.RedirectRequired -> OpdsSignInResult.RedirectRequired(authorizeUrl)
        is OpdsLoginResult.Failed -> OpdsSignInResult.Failed(reason)
    }
}

internal fun acceptableOpdsAcquisition(
    stored: List<OpdsAcquisition>,
    href: String,
    rootUrl: String?,
): OpdsAcquisition? {
    if (!isSameOpdsOrigin(rootUrl, href)) return null
    return stored.firstOrNull { it.href == href }?.takeIf { it.isDirectlyDownloadable }
}

internal fun OpdsAcquisition.toOption(): OpdsAcquisitionOption {
    val action = when (kind) {
        OpdsAcquisitionKind.OPEN_ACCESS, OpdsAcquisitionKind.GENERIC -> OpdsAcquisitionAction.OPEN
        OpdsAcquisitionKind.PREVIEW -> OpdsAcquisitionAction.SAMPLE
        OpdsAcquisitionKind.BORROW -> OpdsAcquisitionAction.BORROW
        OpdsAcquisitionKind.BUY -> OpdsAcquisitionAction.BUY
        OpdsAcquisitionKind.SUBSCRIBE -> OpdsAcquisitionAction.SUBSCRIBE
    }
    val unsupported = unsupportedReason()
    return OpdsAcquisitionOption(
        action = if (unsupported == null) action else OpdsAcquisitionAction.UNSUPPORTED,
        href = href,
        label = title?.takeIf { it.isNotBlank() } ?: defaultLabel(action),
        formatLabel = formatLabel(),
        priceLabel = price?.let { formatPrice(it.currency, it.value) },
        availability = availabilityState(),
        unsupportedReason = unsupported,
    )
}

private fun OpdsAcquisition.unsupportedReason(): String? = when {
    drm == OpdsDrm.LCP -> "Protected by Readium LCP — Enve cannot open this file"
    drm == OpdsDrm.ADEPT -> "Protected by Adobe DRM — Enve cannot open this file"
    format == OpdsFormat.AUDIOBOOK_PACKAGE -> "Readium audiobook package — not supported yet"
    format == OpdsFormat.WEBPUB -> "Readium web publication — not supported yet"
    format == OpdsFormat.DIVINA -> "Readium Divina package — not supported yet"
    isTransactional -> null
    requiresIndirectFetch -> "Needs a fulfilment step Enve cannot complete"
    !format.isReadableContent -> "Enve cannot open this format"
    else -> null
}

private fun OpdsAcquisition.defaultLabel(action: OpdsAcquisitionAction): String = when (action) {
    OpdsAcquisitionAction.OPEN -> "Download"
    OpdsAcquisitionAction.SAMPLE -> "Sample"
    OpdsAcquisitionAction.BORROW -> "Borrow"
    OpdsAcquisitionAction.BUY -> "Buy"
    OpdsAcquisitionAction.SUBSCRIBE -> "Subscribe"
    OpdsAcquisitionAction.UNSUPPORTED -> "Unavailable"
}

private fun OpdsAcquisition.formatLabel(): String? = when (format) {
    OpdsFormat.UNKNOWN, OpdsFormat.OPDS_FEED, OpdsFormat.OPDS_PUBLICATION -> null
    OpdsFormat.AUDIOBOOK_PACKAGE -> "Audiobook"
    OpdsFormat.AUDIO -> "Audio"
    else -> format.name
}

private fun OpdsAcquisition.availabilityState(): OpdsAvailabilityState? {
    if (availability == null && copies == null && holds == null) return null
    return OpdsAvailabilityState(
        state = availability?.state,
        until = availability?.until,
        copiesTotal = copies?.total,
        copiesAvailable = copies?.available,
        holdsTotal = holds?.total,
        holdPosition = holds?.position,
    )
}

internal fun formatPrice(currency: String?, value: Double): String {
    val amount = if (value % 1.0 == 0.0) {
        String.format(Locale.getDefault(), "%.0f", value)
    } else {
        String.format(Locale.getDefault(), "%.2f", value)
    }
    if (value <= 0.0) return "Free"
    val symbol = currency
        ?.takeIf { it.length == 3 }
        ?.let { runCatching { Currency.getInstance(it.uppercase(Locale.ROOT)).symbol }.getOrNull() }
    return symbol?.let { "$it$amount" } ?: listOfNotNull(amount, currency).joinToString(" ")
}
