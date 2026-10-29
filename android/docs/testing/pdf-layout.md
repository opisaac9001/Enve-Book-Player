# PDF two-page layout

`PdfReaderActivity` renders fixed-layout PDFs with `PdfRenderer`. The Appearance sheet offers the same two options as iOS: **Two-page view** and **Show cover separately**. Both default off. The cover toggle stays disabled until two-page view is on.

`PdfReadingLayout` in `:core` is the pure spread policy. With two-page view on, pages pair as [1,2], [3,4], …; with the cover shown separately they pair as [1], [2,3], [4,5], …. An odd trailing page stands alone. `PdfReadingPreferencesStore` persists the layout per profile in the profile's `enve` DataStore, keyed by the book's `uniqueKey` (connection or source plus book id).

The selected page is the canonical page index. It drives the scrubber, progress, and the saved locator. Changing layout recomputes the spread around the selected page without moving it, so no progress sync happens and a later pause or profile checkpoint saves the same page. Previous/next buttons and hardware keys step whole spreads; a turn selects the last page of the destination spread, so the final spread reports completion. Footer text and button availability use spread bounds. Read Next follows the selected page, so a layout change alone cannot trigger it.

Spreads render serially on a single-thread dispatcher because `PdfRenderer` allows one open page at a time. Each page keeps its aspect ratio: pages are scaled to a shared height and drawn side by side into one bitmap, which `ContentScale.Fit` fits to the screen. A render generation counter discards stale results after quick navigation, rotation, or layout changes. The renderer and descriptor close on the same dispatcher after any in-flight render finishes.

## Regression checks

Run `:core:testDebugUnitTest` (`PdfReadingLayoutTest`, `PdfReadingPreferencesStoreTest`) and the connected test class `com.enve.app.ui.screens.PdfReadingLayoutVerificationTest`. Build both debug and minified release.

The instrumented test generates two six-page PDFs with `PdfDocument`, opens them through the real `PdfReaderActivity` as local books, and verifies defaults, the disabled cover toggle, pairing in both modes, actual two-page rendering via screenshots, spread turns to the final pair and back to page 1, scrubber selection by canonical page, no progress write on layout change, the saved page on pause, same-book reopen, and different-book isolation. It cleans up its own fixture files, cached reader copies, book-cache rows, and layout keys.

Manually check both toggles on the Pixel and the e-ink device, rotation in two-page view, reopening a book after force-stop, and a PDF with an odd page count.

## Verification — 2026-10-21

Core and app unit suites passed (147 + 230 tests). Debug and minified release builds passed with no new compiler warnings. The real-reader instrumentation test passed on a connected Pixel 7a, including sampled page colors, both pairing modes, cover return, canonical scrubber selection, unchanged progress after layout changes and pause, portrait/landscape rotation, reopening, and different-book defaults. Captured portrait and landscape screens were inspected. The debug app also cold-started without AndroidRuntime errors.

This verification covers the native PDF reader. Komga server-streamed image pages continue to use the comic reader.
