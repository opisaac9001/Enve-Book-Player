# OPDS catalog, acquisition, and authentication

This describes everything the app does with an OPDS catalog **except** reading position, which has
its own document: [opds-progression.md](opds-progression.md).

Both catalog syntaxes are supported everywhere below:

- **OPDS 1.2** — Atom, `application/atom+xml;profile=opds-catalog`
- **OPDS 2.0** — JSON, `application/opds+json`

`OpdsFeedParser` picks the syntax from the first non-whitespace character of the payload, so a server
that mislabels its `Content-Type` is still read correctly.

## Requests

Every catalog fetch goes through `OpdsCatalogApi` and sends `OPDS_CATALOG_ACCEPT`, which offers both
syntaxes and the single-publication type before falling back to `*/*;q=0.1`. A server that
content-negotiates therefore gets to choose, and one that ignores `Accept` is unaffected.

The catalog API shares the app's `OkHttpClient`, so `DynamicUrlInterceptor`, `AuthInterceptor`, and
`TokenRefreshAuthenticator` apply, and requests carry the credentials of whichever connection owns
the `ConnectionScope` around the call.

### The origin wall

Everything a catalog page offers — a navigation link, a facet, a shelf's `self`, a pagination link,
an OpenSearch description, an expanded search URL — is a string the **server** chose. Two independent
checks keep those strings from turning into credentialed requests to somewhere else:

- `OpdsRepository.getPage` and `OpdsRepository.getDocument` reject a URL that is not on the
  connection's configured root origin **before** they enter `ConnectionScope`, and fail with
  `OpdsForeignOriginException`, which the browser renders as an ordinary error rather than a crash.
  The crawl applies the same rule inside `OpdsCatalogCursor`.
- `OpdsAuthHeaderStrategy` refuses to add an `Authorization` header to a request that is not on a
  configured OPDS origin at all — the scoped connection's origin when there is a `ConnectionScope`,
  any enabled OPDS connection's origin when there is not (which is the cover-image path). A redirect
  that lands off-origin therefore arrives unsigned even if it slipped past the first check.

Origins are compared through `HttpUrl`, so the scheme and host are case-folded and the port is the
effective one: `https://host` and `https://host:443` are the same origin, `https://host:8443` is not.
Anything that is not an absolute `http`/`https` URL has no origin and **fails closed** — it is
neither crawled nor signed.

Every interactive fetch is wrapped so an `IOException`, a malformed body or a parser failure becomes
`OpdsCatalogResult.Failed` with a message the panel can show. `CancellationException` still
propagates, so navigating away cancels cleanly; the browser cancels the in-flight navigation job
whenever a newer one starts, so a slow page can never overwrite a newer one.

## Crawl and pagination

`OpdsCatalogCursor` walks the catalog breadth-first from the connection's root URL, following
navigation links and `rel="next"` pagination, bounded by depth (4), navigation fetches (64),
pagination pages (200), documents (400), and books (20 000). A crawl that hits a bound sets
`truncated`, which the UI reports rather than silently dropping.

Navigation and pagination links are followed **only when they stay on the root's origin**. A catalog
that links out to a different host is a navigation dead end, not a crawl target.

`OpdsRepository` keeps one cursor per connection and accumulates two things as it walks:

- `items` — the flattened, de-duplicated `BookSummary` list, which is what `getItemsPage(page, size)`
  slices. Because it accumulates, page *N* never re-fetches pages *0…N-1*. The previous shape
  re-walked from index 0 on every call and re-fetched any document the cursor had already passed,
  which made a full library crawl quadratic in the number of documents.
- a small LRU of parsed documents (`PARSED_PAGE_CACHE`), which is what `getDocumentPage(index)` —
  the paging source's path — reads. A miss costs one fetch, not a re-walk.

`invalidateCaches(connectionId)` drops both. It is the only way a changed catalog is picked up.

## Structure the UI is given

`OpdsCatalogFacade` (in `:engine-api`) is the only thing `:hearth-ui` may call. It turns a parsed
page into `OpdsCatalogPage`:

| Field | OPDS 2.0 source | OPDS 1.2 source |
| --- | --- | --- |
| `navigation` | `navigation[]` and `catalogs[]` | entries with a `subsection`/`collection`/catalog-typed link and no acquisition link |
| `shelves` | `groups[]` (title, `self`, publications, navigation) | — |
| `facetGroups` | `facets[]`, grouped by each group's `metadata.title` | `rel="…/facet"` links, grouped by `opds:facetGroup` |
| `books` | `publications[]` not already inside a group | entries with an acquisition link |
| `singlePublication` | a bare publication document | a bare `<entry>` document |
| `pagination` | `next`/`previous`/`first`/`last`, `numberOfItems`, `currentPage` | the same Atom link rels plus OpenSearch `totalResults` |
| `search` | `rel="search"` link | `rel="search"` link |

**Single publications are a parser fact, not a count.** `ParsedPage.isSinglePublicationDocument` is
set when the JSON root was itself a publication (it has `metadata` and no `publications`,
`navigation`, `groups` or `catalogs`) or when the XML root was an `<entry>`. A *feed* that happens to
contain exactly one publication is still a feed, and renders as a list.

## Search

`rel="search"` covers two unrelated mechanisms, and both are supported.

- **OPDS 2.0** — the link carries a URI template directly, flagged by `templated: true` or by a `{`
  in the href. It is expanded in place.
- **OPDS 1.2** — the link points at an OpenSearch description document
  (`application/opensearchdescription+xml`). It is fetched on first search, and the `<Url>` element
  whose `type` is an OPDS catalog type supplies the template.

`expandOpdsSearchTemplate` implements the RFC 6570 subset these templates actually use: form-style
`{?query}` / `{?query,author}`, simple `{searchTerms}`, and reserved `{+q}`. The query fills the
first variable whose local name is a recognised search term (`searchTerms`, `query`, `q`, `search`,
`keywords`, `title`); per RFC 6570 every other variable expands to empty, which is also what the
OpenSearch 1.1 spec asks a client to do with optional parameters it does not support. A namespaced
variable (`{?atom:title}`) is matched on its local name and emitted under it, because `:` is not
usable in a query key.

## Acquisition

`OpdsAcquisition` records every acquisition link on a publication: its `rel` (open-access, generic,
sample, borrow, buy, subscribe), media type, resolved format, DRM, indirect-acquisition chain, and
the OPDS commerce metadata — `price`, `availability`, `copies`, `holds`.

### Persistence

Acquisitions are written to `opds_acquisition` as documents are crawled, keyed by
`connectionId:bookId` and ordered by their position in the feed. It is a **side table** for the same
reason `opds_progression_state` is one: `BookCacheDao.upsert` uses `OnConflictStrategy.REPLACE`, so
anything kept on `book_cache` is rebuilt from whatever the current feed carries. A per-book refresh
replaces that book's rows rather than appending, so a link the catalog withdrew disappears.

`MIGRATION_25_26` creates the table and adds `opds_progression_state.authenticateUrl`. Both steps are
guarded (`ensureTable`, a `PRAGMA table_info` check), so the migration is safe to re-run and never
touches `book_cache` rows.

### What the UI offers

`OpdsAcquisitionOption` is the UI-facing shape. The action follows the `rel`:

| `rel` | Action | Behaviour |
| --- | --- | --- |
| open-access, generic | `OPEN` | select this href as the book's acquisition URL, then download through `LibraryFacade` |
| sample, preview | `SAMPLE` | the same, for the sample file |
| borrow / buy / subscribe | `BORROW` / `BUY` / `SUBSCRIBE` | hand the href to the system browser — these are web transactions, not file downloads |

`selectAcquisition` writes the chosen href to `book_cache.opdsAcquisitionUrl` for that book, which is
what `OpdsProviderAdapter.getEbookDownloadUrl` and `getAudioTracks` read. It re-validates at the
facade boundary rather than trusting the option the UI hands back: the href must be on the
connection's root origin, must be one of the hrefs stored for that book, and that stored acquisition
must still be directly downloadable — no DRM, a format the reader can open, not transactional, and
no fulfilment chain. It returns `null` when any of that fails or when the book is not in the cache
yet, and the option falls back to opening externally.

`resolveOpdsAcquisitionUrl` applies the origin rule again when a download actually starts, which is
what contains `MIGRATION_24_25`: that migration copied an OPDS book's `id` into
`opdsAcquisitionUrl` whenever the id looked like a URL, and an id is a server-chosen string. The
migration is left as it shipped — rewriting history would make an already-migrated database
disagree with a fresh one — and the runtime guard refuses the laundered value instead.

Price is rendered from the currency code's symbol where the JVM knows one (`$4.99`), from the bare
code where it does not (`9 ZZZ`), and as `Free` at zero. Availability, copies, and holds are rendered
as a single line (`Unavailable · 0 of 5 available · hold #2 · until 2026-02-01`).

### What the app will not pretend to open

An option carries `unsupportedReason` and stops being actionable when it is:

- protected by **Readium LCP** or **Adobe DRM (ACSM)**
- a **Readium package** — audiobook manifest, WebPub, or Divina
- a free download that **requires a fulfilment step** (an indirect-acquisition chain)
- any other format the reader cannot open

A transactional link is exempt from the fulfilment check: borrowing through a website is exactly how
those links are meant to work.

## Authentication (OPDS Authentication 1.0)

A `401` from any catalog fetch is turned into `OpdsAuthenticationRequiredException`, carrying the
parsed Authentication Document from the response body. `OpdsCatalogFacade` surfaces it as
`OpdsCatalogResult.AuthenticationRequired` and the browser shows a sign-in panel instead of an error.

Discovery requests offer both media-type spellings — `application/opds-authentication+json` and the
older `application/vnd.opds.authentication.v1.0+json` — and the body is accepted on its shape rather
than on the `Content-Type` a server happens to declare.

| `type` | Flow | What the app does |
| --- | --- | --- |
| `…/auth/basic` | `BASIC` | stores the username and password, signs every request with `Authorization: Basic` |
| `…/auth/oauth/password` | `OAUTH_PASSWORD` | RFC 6749 password grant against the `authenticate` link, stores the bearer |
| `…/auth/oauth/implicit` | `OAUTH_IMPLICIT` | opens `OpdsAuthBrowserActivity`, reads the token out of the redirect fragment |
| anything else | `UNSUPPORTED` | listed but not offered |

The document's `labels.login` / `labels.password` are used verbatim as field labels, so a library
that asks for a "Card number" and a "PIN" says so. `help` links are resolved against the document URL
and dropped unless they are `http`/`https`.

### Storage

`OpdsAuthStore` is an `EncryptedSharedPreferences` file (`enve_opds_auth`) keyed by connection ID. It
holds the flow, the Basic username/password, the bearer and refresh tokens, the token and refresh
endpoints, and the absolute expiry. It is deliberately separate from `CredentialVault`: OPDS
sessions are per-connection OAuth state rather than the single token-per-connection shape the vault
models, and keeping them apart meant no change to the shared credential path.

### Signing and renewal

Two Hilt multibindings do the work, and neither adds an OPDS branch to a shared interceptor:

- `OpdsAuthHeaderStrategy` (`@AuthHeaderStrategyKey(OPDS)`) — a stored bearer wins, then stored Basic
  credentials, then the connection's own username/token. A request that already carries an
  `Authorization` header is left alone, and so is one that is not on a configured OPDS origin.
- `OpdsTokenRefreshStrategy` (`@TokenRefreshStrategyKey(OPDS)`) — used by the `401` retry path. It
  prefers the refresh-token grant against the `refresh` link and falls back to replaying the password
  grant with the stored credentials. The renewed token is written back to `OpdsAuthStore`.

`OpdsOAuthClient` exposes the grants twice. `password` is a `suspend` function that hops to
`Dispatchers.IO`, because sign-in is driven from a ViewModel on the main thread and a blocking
`execute()` there is a `NetworkOnMainThreadException`. `passwordBlocking` and `refreshBlocking` stay
blocking for `OpdsTokenRefreshStrategy`, which runs on OkHttp's own thread inside an `Authenticator`
and must not suspend. Both paths turn an `IOException` into a refused sign-in rather than an
exception crossing the interceptor chain.

### The implicit flow

`OpdsAuthBrowserActivity` is a dedicated, unlocked activity. It mints a 256-bit `SecureRandom` state
for the flow and **always** sets `response_type=token`, `redirect_uri=enve://opds-auth` and that
state on the authorization endpoint, overwriting whatever the server prebuilt — a server that
supplies its own `redirect_uri` is describing where it would like the token sent, which is exactly
the parameter that must not be taken on trust. A non-`http`/`https` authorize URL is refused.

The state lives in a `ViewModel`, so it survives rotation and dies with the task; it is never written
to `onSaveInstanceState`, a preference or the database. A process death therefore invalidates the
flow rather than leaving a replayable state on disk.

`shouldOverrideUrlLoading` consumes every non-`http` navigation, so an `intent://` or `file://` URL
never reaches the WebView, and it only completes the flow for a **main-frame** navigation whose URI
matches the redirect exactly on scheme, authority and path — `enve://opds-auth.evil.example.org` and
`enve://opds-auth/steal` are not the redirect URI, and a prefix match would have accepted both.
Completion happens once per flow.

The callback is read from the **fragment** only, as RFC 6749 §4.2.2 specifies for the implicit grant;
a query-string `access_token` is never honoured. The `state` must be present and equal to the flow's
own, for an error response as much as for a token. Then `access_token` / `refresh_token` /
`expires_in` are read, a non-Bearer `token_type` is rejected, and an `error` parameter is reported
rather than treated as a sign-in. Every rejection surfaces on `OpdsCatalogFacade.signInFailed`, which
the browser shows on the sign-in panel. The WebView is detached, stopped and destroyed in
`onDestroy`.

Signing in invalidates the connection's cursor and emits on `OpdsCatalogFacade.signedIn`, so the
open catalog page reloads itself with credentials.

## Where the code is

- `engine/…/data/repository/OpdsFeedParser.kt` — both syntaxes, one `ParsedPage`
- `engine/…/data/repository/OpdsCatalog.kt` — acquisition model, selection, origin helpers
- `engine/…/data/repository/OpdsRepository.kt` — crawl, cursor, accumulation, `401`
- `engine/…/data/opds/OpdsCatalogApi.kt` — the catalog request and its `Accept`
- `engine/…/data/opds/OpdsAcquisitionState.kt` — the `opds_acquisition` side table
- `engine/…/data/opds/OpdsSearch.kt` — OpenSearch descriptions and template expansion
- `engine/…/data/opds/OpdsAuthenticationDocument.kt` — Authentication Document parsing
- `engine/…/data/opds/OpdsAuthStore.kt` — encrypted per-connection sessions
- `engine/…/data/opds/OpdsAuthStrategies.kt` — the header and refresh multibindings
- `engine/…/data/opds/OpdsOAuthClient.kt` — password and refresh-token grants
- `engine/…/hearth/OpdsCatalogFacadeImpl.kt` — the facade the UI sees, and the acquisition re-check
- `engine-api/…/opds/OpdsCatalogFacade.kt` — the contract
- `hearth-ui/…/opds/` — the catalog browser
- `app/…/ui/auth/OpdsAuthBrowserActivity.kt` — the implicit-flow browser
