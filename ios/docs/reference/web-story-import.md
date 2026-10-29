# Web story import

iOS can save a web article or serial as a local EPUB. Open **Library → Add books → Import from link**, or **Add source → Web link**. Paste a complete HTTP or HTTPS address and choose **Preview** before importing.

Royal Road fiction pages expose a chapter list. The importer collects all pages of Royal Road's chapter table. Chapter links also look for the parent fiction page, preserving its published order. The preview offers **This chapter**, **From here**, or **Whole story** where applicable. The pasted chapter is selected when importing from a chapter link; a fiction index defaults to the whole story. Other websites import the current article and can expose a chapter list through `#chapters` or `.chapter-row` links containing `/chapter/<id>`.

Use **Open in browser** for sites that require sign-in or a verification step. Navigate normally, then choose **Import this page** to preview the rendered page. Browsing uses an isolated, nonpersistent WebKit session. Enve does not bypass site access controls. A blocked, missing, or unreadable chapter stops the import rather than adding an incomplete book.

## Saved content

The EPUB preserves readable text, headings, emphasis, lists, code, and tables. It includes author and title metadata, ordered reader contents, the original source address, and a source link in each chapter. Scripts, forms, ads, navigation, comments, and CSS-hidden text are excluded. Image descriptions are retained as text; images are not downloaded.

The resulting book uses Enve's existing profile-specific file import pipeline and works with the normal reader, reading progress, and text-to-speech. Choosing Done from the library import shows the device library with content filters and search cleared. Imports are snapshots: new chapters are not synchronized automatically, and importing again creates another local book.

Direct supported ebook-file links use the existing file import pipeline. HTTP downloads use an ephemeral URLSession rather than the browser's authenticated cookies. A plain text webpage can also be converted into an EPUB. Audio, arbitrary attachments, and protected file downloads are outside this flow.

## Implementation

- `WebStoryPageLoader` owns the session WebKit view, navigation, isolated-world extraction, cancellation, and load deadlines.
- `WebStoryExtraction` detects article content and Royal Road metadata and serializes a sanitized XHTML fragment using rendered visibility.
- `WebStoryImportService` prepares a preview, resolves chapter selection, fetches chapters serially, and owns temporary staging. Subsequent chapter fetches are paced. Failed or cancelled staging removes its output.
- `WebStoryEPUBBuilder` writes an EPUB 3 archive incrementally, with the uncompressed `mimetype` first, OPF metadata, navigation, NCX, and one XHTML document per chapter.
- `SourcesWebImportScreen` owns preview and browser interactions. `SourcesEngine.importFiles` commits the finished file to the current profile's local library.

The new files are excluded from tvOS. No new dependencies, provider type, authentication store, background job, or persistence schema are required.

## Verification

`WebStoryImportTests` exercises URL validation, rendered Royal Road extraction, hidden ancestors, isolated JavaScript execution, paginated chapter ordering and deduplication, XHTML sanitization, EPUB structure, real Readium metadata extraction, chapter selection, and cancellation cleanup. `WebStoryImportUITests` serves an original two-chapter fixture over a local HTTP listener and exercises browser back/forward navigation, page preview, import, reader contents, rejection of an unavailable chapter, and validation with accessibility text in Paper mode.

On October 25, 2026, the iPhone Air simulator build passed. The complete AllTests plan passed with parallel testing disabled: **1,660 passed, 36 skipped, zero failures**. An earlier parallel run hit two authentication-test wait timeouts; both passed on the complete rerun. All **four fixture UI tests** passed. A separate live Royal Road test detected all **144 available chapters** of *New Life as a Max Level Archmage*, imported its first chapter, and opened the saved EPUB in Enve's reader. The signed device build succeeded and was installed on the connected iPhone 16 Pro without replacing its data. The existing `CloudKitSink.swift` Sendable warning remains; no new compiler warnings were introduced.

The live UI check is opt-in using `ENVE_WEB_IMPORT_LIVE_URL` in the test runner environment; `ENVE_WEB_IMPORT_LIVE_CHAPTER_COUNT` optionally asserts a known chapter count. It uses the public *New Life as a Max Level Archmage* example. These assertions must follow the site's current available chapters, since authors can add or remove them.

The automated fixtures contain original test prose, not downloaded stories. Live sites can change their markup, rate limits, or access requirements independently of these tests.

## References

- [ElevenReader content import](https://elevenlabs.io/docs/help-center/product/mobile-apps/elevenreader/how-do-i-add-content-to-elevenreader): pasting a link saves webpage content.
- [ElevenReader Chrome extension](https://elevenlabs.io/docs/help-center/product/mobile-apps/elevenreader/how-does-the-elevenreader-chrome-extension-work): can combine subsequent story chapters.
- [ElevenReader Open a webpage](https://elevenlabs.io/docs/help-center/product/mobile-apps/elevenreader/how-does-open-a-webpage-work): live webpage listening is separate from saving to the library.
- [Royal Road visibility issue](https://github.com/mozilla/readability/issues/984): hidden content must be removed using rendered visibility.
