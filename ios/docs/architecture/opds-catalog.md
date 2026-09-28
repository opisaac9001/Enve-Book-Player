# OPDS catalog

Enve reads OPDS 1.x (Atom) and OPDS 2.0 (JSON) through one parser, and uses the result two ways.

**Import** flattens a catalog into a book list and reconciles the library against it. That is the right
shape for a library and the wrong one for discovery: it drops the navigation, the groups, the facets, the
search, and every publication no acquisition delivers a file for.

**Browsing** keeps all of it. `SourcesOPDSBrowseScreen` walks one page at a time through
`OPDSCatalogBrowser`, and performs the acquisitions an import cannot represent — a sample, a purchase, a
loan, a subscription.

Both call `OPDSFeedParser.parse(document:context:)`. There is one wire model and one set of rules; the two
callers differ only in what they keep.

## The parsed page

`OPDSParsedFeed` carries an `OPDSCatalogPage` plus what the traversal needs. Everything else is derived
from the page, so the two views cannot drift apart.

| Member | OPDS 2.0 | OPDS 1.x |
|---|---|---|
| `navigation` | the `navigation` collection | an `<entry>` whose only usable link is a sub-feed |
| `groups` | the `groups` collection, each with its own `self` link | — |
| `facetGroups` | the `facets` collection, grouped by each facet's own metadata title | feed-level `rel="http://opds-spec.org/facet"` links, grouped by `opds:facetGroup`, honouring `opds:activeFacet` |
| `catalogs` | the `catalogs` collection | — |
| `publications` | the `publications` collection | every `<entry>` carrying an acquisition |
| `pagination` | `first`/`previous`/`next`/`last` links plus `numberOfItems`, `itemsPerPage`, `currentPage` | the same link relations |
| `search` | the `search` link's URI Template | the `search` link's OpenSearch description |
| `authenticationDocumentURL` | a link to an OPDS Authentication Document | the same |

Pagination and navigation are separate axes. `next` continues *this* collection; a navigation entry
descends into *another* one. Conflating them would either re-import a collection under two identities or
stop paging as soon as a sub-feed appeared.

A group's publications belong to the catalog, not to a preview of somewhere else, so
`OPDSCatalogPage.allPublications` includes them and the import keeps them. Facets are **not** followed by
the import: they are alternative views of the same collection, and walking them would import every
publication again.

## Publications

`OPDSPublicationEntry` is what the catalog said, before Enve decides what it can do with it. It keeps every
acquisition the entry offered — ordered most permissive first — and either the `Book` an import takes or
the reason there is none.

| Field | Meaning |
|---|---|
| `identity` | `metadata.identifier`, then the `self` link, then the acquisition URL. Acquisition URLs routinely carry an expiring token, so they are the last resort: using one would churn book IDs on every refresh. |
| `declaredIdentifier` | what the entry itself declared, which is the only identifier the rejected-content surface can match a server-side item against |
| `coverURL` / `thumbnailURL` | separate. A thumbnail is not a smaller cover to Enve: it is the image a list row loads. A feed that declares one through `rel` gets used as written; otherwise the smallest image with stated dimensions stands in. The imported `Book` always keeps the full-size cover. |
| `fulfillable` | the first acquisition that delivers a file Enve can open and is not reported unavailable |
| `sample` | a `preview`/`sample` acquisition Enve can deliver. A sample is a real file, so it is offered — but only when the reader asks for it by name, never as the acquisition an import silently chooses. A downloaded sample is adopted into the local library rather than the catalog's, because the next complete snapshot would otherwise delete it. |
| `unavailableSampleReason` | why a sample the entry advertises cannot be fetched — an audio preview, protected packaging, an unreadable format. The row says so rather than offering a button that does nothing. |
| `transactions` | `buy`, `borrow`, `subscribe`. These open in the browser; Enve performs no transaction of its own. |
| `unavailableReason` | one sentence naming the DRM scheme, the packaging, the price, the copies and holds, or the availability window the feed reported |

Nothing is dropped for being unopenable. A publication under Readium LCP, a Readium audiobook package, a
purchase-only title and a loan with every copy out all appear in the browser with their terms, and in the
rejected-content surface after an import.

## Modification dates

An imported book is stamped with the date the catalog gave it: `metadata.modified` in OPDS 2.0, `<updated>`
in Atom. An entry that dates nothing is stamped `Date.distantPast`.

This is load-bearing rather than cosmetic. `BookRecord.update(from:)` overwrites stored progress only when
the incoming book is at least as new as the record, so stamping an import with "now" makes every catalog
refresh look newer than the reader's own position — and erases it. `.distantPast` is the only honest answer
for an entry with no date: an OPDS catalog knows nothing about where the reader is.

It is also what makes progression conflict ordering mean anything. `OPDSProgressionSyncStrategy` compares
the service's `modified` against the book's `lastUpdate`; if the latter were the time of the last import,
the local side would always win.

## Language

Readium metadata keys every human-readable string by language. `OPDSLanguagePreference` picks one with BCP
47 lookup against `Locale.preferredLanguages`: an exact tag, then a tag sharing the primary subtag, so a
reader who asked for `fr-CA` still gets `fr`. After that come `en`, Readium's `und`, and finally the
alphabetically first key — the last two exist only so two runs of the same catalog cannot disagree about a
title.

## Search

| Dialect | Where the query comes from |
|---|---|
| OPDS 2.0 | the `search` link's URI Template, expanded by `OPDSURITemplate` (RFC 6570 level 3) |
| OPDS 1.x | the OpenSearch description the `search` link points at, fetched on first use; its `Url` templates are ranked and the one returning an OPDS feed wins |

A `search` link whose `href` contains braces is treated as a template even when the link does not declare
itself templated, because OPDS 1 feeds routinely write it that way.

Catalogs name the query variable differently — `query`, `searchTerms`, `q`, `keywords`, `title` — so
`OPDSSearchDescriptor.values(forTerms:in:)` fills whichever the template asked for, and answers a template
that also wants a page or a count with the first page. A variable the template names and Enve has no value
for is dropped, which is exactly what RFC 6570 does with an undefined variable and what OpenSearch's
`{name?}` optional marker means.

The descriptor a root feed published is carried down as the reader descends, because a sub-feed rarely
repeats the `search` link.

## Acquisition and fulfilment

An acquisition does not always answer with the file. OPDS 1 indirect acquisition hands back an entry
document and OPDS 2 a publication document, each naming the next link in the chain.

`OPDSProvider.downloadPublication(from:for:onProgress:)` follows those hops. When a response declares
`application/atom+xml`, `application/opds+json` or `application/opds-publication+json`, the body is parsed,
its own acquisition is selected, and the download restarts there — up to
`OPDSAcquisitionFulfillment.hopLimit` times. A chain that points back at itself, or that ends at something
Enve cannot open, is reported rather than written into the library.

The final response is still checked by `resolveDownloadedFormat`: a DRM licence, an HTML sign-in page, or
bytes that do not match the declared format are refused there, which is the last line of defence against
writing a login page into the library as an EPUB.

## Credentials and transport

Credentials are scoped to the configured feed origin, at every layer:

- `applyCredentials` attaches `Authorization` and the connection's custom headers only on that origin. The
  value is a token the reader entered, then a bearer token an
  [OPDS Authentication](opds-authentication.md) flow produced, then HTTP Basic.
- Basic is written out as a header rather than left to the session's challenge handler, because the paths
  that carry a publication — `AVURLAsset`, the background download session, the image cache — never see a
  challenge. They send headers or they send nothing. `credentialHeaders(for:)` is what they get: the
  credentials and nothing else, because each of them supplies its own `Accept` and handing it the feed's
  would have a strict server answer `406` to a request for audio. It still stops at the feed origin, and
  `getAudioURL` refuses a cross-origin audio acquisition outright.
- A redirect is governed by `HTTPRedirectPolicy`: a destination on another scheme, carrying its own
  `user:password@` userinfo, or downgrading `https` to `http` is not followed at all, and any cross-origin
  hop sheds `Authorization`, `Cookie`, `Proxy-Authorization` and every header whose name reads as a
  credential.

`validateConnection` parses the response rather than sniffing it. A sign-in page, an API error object and a
JSON document that merely mentions `metadata` all answer `200`, and the last of them would import as an
emptied catalog — which reconciliation acts on by deleting every book in it.

## Walking the catalog

`OPDSCatalogBrowser` keeps a trail — root first, the last entry being the page on screen — and three rules
keep it honest:

- **The trail only moves on a load that succeeded.** A refused descent, a refused Back and a refused reload
  all leave the reader on the page they can still see, with the reason on screen. A Back step that shortened
  the trail before the parent arrived would let the next Back skip a level the reader never returned to.
- **A refused root has nothing to fall back to**, so it clears the page and the trail — and `reload` then
  loads the feed rather than finding no step to repeat. That is the state a sign-in exists to get the reader
  out of, and `reloadAfterSignIn` rebuilds the provider first, because a Basic flow writes the login and
  password onto the connection the provider was built from.
- **A selection belongs to its page.** `selection` is reconciled against every page that loads, so
  `Import 3` cannot name publications that are no longer on screen and then import none of them.

Every URL the browser is handed comes out of the feed, so `OPDSURL.resolve` applies `isRequestable` itself:
navigation, catalogs, facets, pagination, acquisitions, covers, search templates and authentication
documents are all held to http(s), a real host, and no `user:password@` userinfo of their own.

## Snapshot completeness

`OPDSCatalogTraversal` treats every guard as a runaway guard, not a library-size cap:

| Guard | Default |
|---|---|
| navigation depth | 10 |
| navigation links per feed | 200 |
| `next` pages within one feed | 2,000 |
| feed requests per import | 5,000 |

Hitting one marks the snapshot **incomplete** and records a notice. Only the root request may fail the
whole import; a sub-feed or continuation page that cannot be read makes the snapshot partial instead. A
partial snapshot never deletes books, and never retires a progression service.

## Where the code lives

| Path | Responsibility |
|---|---|
| `enve/Networking/Providers/OPDSProvider.swift` | The provider, the wire model, both parsers, acquisition selection and fulfilment |
| `enve/Services/OPDS/OPDSCatalogBrowser.swift` | Page-at-a-time navigation, search and acquisition state |
| `enve/Services/OPDS/OPDSURITemplate.swift` | RFC 6570 expansion |
| `enve/Services/OPDS/OPDSLanguagePreference.swift` | BCP 47 lookup over Readium's language-keyed strings |
| `enve/Services/OPDS/OPDSBulkImportService.swift` | Downloading a chosen set into a collection |
| `enve/Screens/Sources/SourcesOPDSBrowseScreen.swift` | The browse surface |
| `enve/Utilities/HTTPRedirectPolicy.swift` | Which redirects are followed, and what travels with them |

Progress sync is [OPDS Progression](opds-progression.md). Signing in is
[OPDS Authentication](opds-authentication.md).
