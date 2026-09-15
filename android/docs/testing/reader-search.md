# EPUB search

Readium EPUB searches use `EbookSearchService` in `:engine`. Rendering and result navigation remain with Readium. Foliate keeps its existing search implementation.

The first search lazily indexes reading-order resources, showing progress and provisional matches. Each section commits atomically, so interrupted searches resume from completed sections. Cancellation stops the UI immediately; an already-started section transaction finishes before releasing its database handle. A completed index avoids EPUB extraction on subsequent searches.

Indexes are disposable Room databases under `cache/ebook-search-index`, separate from reader data and annotations. SHA-256 cache keys include ZIP entry names, CRCs, sizes, and the index schema version. Changed EPUBs receive new indexes. Closed indexes are evicted least-recently-used above a 150 MiB cache budget. Corrupt indexes are rebuilt. Android can also evict this cache.

Whole-word search uses FTS4 candidate selection for ASCII-normalized queries, followed by literal phrase verification. Partial-word and other Unicode queries scan cached chunks to avoid tokenizer-related omissions. Case and accents are normalized with original-offset mapping for snippets. Search text is limited to 200 characters. The whole-word preference persists independently of the reader theme.

Exact semantic heading matches (`h1`–`h6`, `dt`) rank first when their locations can be verified against the extracted text. Other matches retain reading order. Bold text is not assumed to be a dictionary entry. The UI initially shows 100 matches and offers further batches of 100.

Result navigation dismisses the sheet and chrome before resolving the quote, allowing the system-bar transition to settle. The original-text quote is resolved against the loaded DOM and handed to Readium with a precise CSS scope and DOM-native context. Search does not insert markers or change element IDs. If precise resolution is unavailable, the Readium locator remains the fallback.

## Regression checks

Run `:engine:testDebugUnitTest`, `:app:testDebugUnitTest`, and the connected test class `com.enve.app.readium.EbookSearchServiceTest`. Build both debug and minified release.

The instrumented fixtures cover accents, literal operators, phrases, partial words, CJK, heading ranking, pagination, cache reuse, changed EPUBs, cancellation/resume, corruption, and Unicode chunk boundaries.

The optional `searchDictionaryPath` instrumentation argument enables a timing test against a locally supplied Webster dictionary EPUB. No dictionary is bundled with the tests.

Manually check search, cancellation, query replacement, loading more results, and tapping a result in a large EPUB. Verify the result opens at the matching text, then repeat after closing and reopening the reader. Check the supported e-ink device separately from the Pixel.

## Device verification — September 13, 2026

Public fixture: Project Gutenberg's Webster's Unabridged Dictionary, ebook 29765; 12.3 MB EPUB, 190 reading-order resources. These are single-run debug measurements, not release-performance guarantees.

| Device | First index, absent query | Cached absent query | Cached first 100 matches |
| --- | ---: | ---: | ---: |
| Pixel 7a, Android 17 | 28.1 s | 15 ms | 898 ms |
| Bigme HiBreak, Android 14 | 145.4 s | 171 ms | 8.75 s |

The positive-query benchmark includes the publication's first positions lookup; the normal reader prepares positions when opening the book. An initial index is more expensive than one plain text scan, so its benefit is repeated searches. Partial-word and non-ASCII searches are not guaranteed to have FTS latency.

Device dogfooding verified progressive dictionary results, cancellation/resume on the Bigme, and exact navigation to the BETTONG passage containing “kangaroo” on both devices. The Pixel also opened the distinct Aquila audax occurrence in another resource. The original reporter's Oxford EPUB was not supplied, so this does not establish reproduction or resolution of that exact file-specific report.

The Pixel loaded 200 results through the UI and retained the partial-word option after a force-stop/relaunch. The option was restored to whole-word mode after testing. Both devices passed nine functional instrumentation checks, plus the separate full-dictionary benchmark. The functional suite includes immediate query replacement during indexing and repeated-quote DOM navigation with Unicode preceding text. All 303 app/engine unit tests passed; debug and minified release builds completed with zero errors and no new warnings.

The public Webster test book remains in the debug app's scoped local test library on each device for follow-up checks. No release was published.
