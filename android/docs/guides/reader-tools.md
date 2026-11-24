# Reader tools

## Fonts and page turns

Settings → Home & appearance → Reader & custom fonts → Custom Fonts offers 32 curated Google Fonts families. Preview downloads one face; Download installs the available regular, bold, and italic faces. Installed fonts remain available offline. Nothing from this catalog is bundled in the APK. Users can still import their own TTF/OTF files.

EPUB Appearance and PDF Appearance include Standard and Page curl. Curl applies to EPUB edge taps/page keys and PDF arrows/page keys; native swipes retain the reader's existing motion. Scrolling, e-ink, reduced motion, and disabled system animations suppress curl. EPUB also respects Animate page turns. The selection is saved per profile.

The text-selection menu includes Translate and Wikipedia. Translation uses Android's translation action when available, with a browser fallback. Lookups send only the explicitly selected text after the user chooses the action.

## Imports, Calibre, and shortcuts

Android Open with and Share accept supported book files. Enve displays a review screen before copying selected files into the active profile's offline storage. EPUB and PDF readers use these copies without needing the original file or a server connection.

Add a source → Set up manually → Calibre prepares the server's OPDS address and opens the existing OPDS sign-in flow. This supports catalog browsing and book downloads; Calibre reading progress and library edits are not synced.

The launcher offers Read and Library shortcuts. Read resumes the profile's most recently opened ebook when available. Shortcut labels contain no book metadata, and profile access checks still apply.

## Highlights and Readwise

Annotation exports share actual files in Markdown, text, CSV, JSON, HTML, Web Annotation JSON, or PDF. PDF exports wrap text across pages. Exported files are temporary copies; sharing does not change annotations.

Readwise supports a profile-specific API token, connection validation, an export preview, and explicit confirmation. Users may export all books or one book. Successful exports retain remote IDs and content fingerprints so retries skip unchanged highlights and update edited notes. Cancellation retains completed receipts. A lost create response is reconciled before retrying the update.

Highlights exceeding Readwise's 8,191-character limit are skipped with an explanation. No real account data is sent until the user confirms the preview. Tokens stay in the credential vault; the Readwise client does not follow redirects or log request contents.

## Goals and recaps

Journal supports a daily ebook-reading goal from 1 to 240 minutes. Listening time is excluded from that goal. Goals are disabled until configured and saved per profile.

Journal → Recaps offers month/year selection, reading/listening totals, active days, sessions, top books, authors, and narrators where metadata exists. Users can share text or a PNG card. Figures use locally retained session history and the current timezone. The existing history facade returns up to 1,000 recent sessions, so older periods can be incomplete. Completion dates are unavailable; recaps do not invent finished-book counts.

## Kavita covers

The catalog requests the appropriate series, volume, or chapter cover, including locked custom series artwork for standalone items. Known modification timestamps version the image cache. When Kavita supplies no timestamp, the revision stays stable during ordinary reads and changes on an explicit library refresh. This avoids downloading unchanged covers on every home-screen read while allowing replacement artwork to refresh.

Current servers use authenticated image requests. Older servers that require an image API key use an in-memory account-key fallback. Persisted catalog URLs contain no credentials.

## Verification

Debug and minified release builds, core/engine/Hearth/app unit tests, and the `com.enve.app.cloud` instrumented suite cover this batch. Device checks used a Pixel 7a with synthetic local books: EPUB/PDF import, EPUB artwork, font preview/download/application/offline reading, goals, month/year recaps and image sharing, forward/backward page curl, restored PDF position, translation, Calibre setup, and the Library launcher shortcut.

The instrumented suite checks legacy Kavita cover authentication, replacement artwork and disk-cache reuse, multipage PDF exports, recap PNG generation, Readwise confirmation/cancellation, incoming intent handling, and curl rendering. Readwise uses a fake facade or mock server in tests; no real account highlights were exported. Live Calibre catalog access and custom artwork on a real Kavita server remain integration checks before release.

API references: [Readwise](https://readwise.io/api_deets), [Calibre Content server](https://manual.calibre-ebook.com/server.html), [Google Fonts source](https://github.com/google/fonts), [Android translation action](https://developer.android.com/reference/android/content/Intent#ACTION_TRANSLATE), and [Kavita source](https://github.com/Kareadita/Kavita).
