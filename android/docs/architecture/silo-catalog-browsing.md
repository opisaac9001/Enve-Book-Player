# Silo catalog browsing

The library's Books view queries Silo directly for ordinary browsing, text search, genres and languages. It loads 50 summary cards per library and follows opaque cursors with Load more. Changing the query, filters, media type, source, library or connection cancels the previous request and starts a new traversal. Text entry is debounced by 250 ms.

Unfiltered browsing uses `GET /api/v2/catalog`; genre/language selections use `POST /api/v2/catalog/query`. Values within one category are ORed, and categories are ANDed. Filtering happens before pagination. The POST endpoint accepts at most 100 items; Enve requests 50. Summary cards do not trigger per-book detail calls. Opening a book or starting a download resolves its details on demand, retaining summary language and genres if the detail response omits them.

Genre and language options use `/api/v2/catalog/filters/search`, after checking `facet_value_search` in `/api/v2/catalog/search/capabilities`. The sheet displays up to 24 matching options per category plus selected values. A hint explains when more matches exist. Servers without this capability show an update/retry message rather than treating a capped facet list as exhaustive.

Title ascending and recently added descending are supported. Other sort selections use title order with a visible explanation. Personal/Goodreads ratings, series membership/standalone, status filters and contributor groupings operate on cached books and are labeled accordingly. The cache-backed library view includes at most 1,200 ordinary Silo rows plus downloaded/in-progress rows; these local-only results may be incomplete. Non-Silo sources retain their existing behavior. Saved-list membership resolves individual book keys instead of loading the complete Silo mirror.

Refresh imports only 12 recent summary cards per Silo library and never uses that partial response to delete cached books. Existing detailed records are preserved. Viewed pages insert missing summary records in a single batch so playback queues and progress have stable identities; existing rows are not replaced. Paging does not authorize catalog deletion. Reader launch resolves an unknown format before choosing the EPUB, PDF or comic reader.

Connectivity failures fall back to matching downloaded files, validated through the download stores rather than the cached download flag. There is no 40-book limit on this fallback. Library/account exclusions and media/genre/language/text filters remain in effect. Authentication, TLS, decoding and server failures remain visible errors; they are not silently reported as an empty or offline library. Interactive requests have an eight-second timeout and retain per-connection request scope.

Implementation boundaries:

- `core/data/provider/RemoteCatalogBrowsing.kt`: shared provider contract and request types.
- `silo/SiloRemoteCatalog.kt`, repository and adapter: wire protocol and summary/detail mapping.
- `engine-api/library/RemoteLibraryCatalog.kt`: UI-facing requests and results.
- `engine/hearth/RemoteLibraryCatalog.kt`: enabled connection/library scope, paging, metadata overlay and verified-file fallback.
- `hearth-ui/library/LibraryRemoteCatalog.kt`: request policy, cancellation, pagination and filter option state.

The provider, engine and UI unit suites cover wire requests, filter matching, error classification, cursor handling and stale-response cancellation. `SiloRemoteCatalogUiTest` is an opt-in connected-device lab check, using a loopback relay and a temporary family profile; its cleanup phase restores the previous profile. Ordinary test runs skip it.
