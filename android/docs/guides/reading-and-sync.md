# Reading, home controls, and Hardcover setup

## Page turning

Open an ebook, open the reader's appearance controls, and enable **Volume-button page turning**. Volume down goes forward; volume up goes back. The setting is saved for future reading sessions. When audio is playing, these keys keep controlling its volume. Comics have the same option in their reader settings. PDF volume navigation is not currently available.

## Home and navigation

Under **Settings → Home & appearance**, switch off **Book shortcut in dock** to remove the last-book row and its swipe-to-open gesture. Navigation tabs remain available. Reopen books from Hearth or Library; audio controls also remain in the playback notification.

**Library overview** replaces the old “Today's stack” label. It summarizes the in-progress shelf, downloaded books, and recently added shelf. These are library counts, not books read today. Recently added reflects the items in that shelf, not a daily total. Switch off **Library overview** in the same settings page to reclaim that space. Shelf order remains configurable independently.

Choose an accent preset under **Theme & accent**, or use **Reader & custom fonts** for a custom colour. Custom colours apply to the app accent; ebook page backgrounds are selected in the reader itself.

## Ebook sync interval

Under **Settings → Library & reading → Reading**, choose an **Ebook sync interval**: Automatic, 30 seconds, 1 minute, 5 minutes, or 12 minutes.

Automatic preserves the existing short debounce. Other choices combine routine ebook progress changes into the latest position before sending it to the server. Local position saves retain their normal cadence. Leaving the reader flushes the latest position immediately, so this is not a strict hourly API-request limit. One progress update can make several provider requests. Offline retries, manual refresh, audio/read-along, comics and PDFs have their own timing. Opening a book still checks for remote progress normally.

## Hardcover

Hardcover is an optional outgoing reading tracker. It receives reading status and progress for linked books; it does not provide the position used to resume an ebook in Enve.

1. Open [Hardcover Settings → API](https://hardcover.app/account/api), create a key named **Enve**, and choose an expiry.
2. For reading sync, select the permissions below. Full account access (`all`) is unnecessary.
3. In **Settings → Services & tools → Hardcover**, paste the key and connect. A leading `Bearer` is accepted.
4. Enable reading-progress sync. Link each Enve book to the correct Hardcover book and edition in Hardcover Hub when it needs matching.
5. Read or listen, then check the Hub's sync status. Failed entries can be retried there.

| Permission | Needed for |
| --- | --- |
| `read:me:content` | Identifying your Hardcover account |
| `read:catalog:search` | Finding books and editions, including identifier lookups |
| `read:library` | Reading existing library entries, status and reading sessions |
| `write:library` | Adding linked books and updating status, dates and reading progress |
| `read:lists` | Optional: displaying your lists |
| `read:goals` | Optional: displaying your reading goal |
| `write:goals` | Optional: creating or changing your reading goal |

Enve does not need email, account-management, social-write, review-write or catalog-edit permissions. A key intended only for browsing can omit write permissions, but cannot update reading progress or goals. A missing optional permission can leave that Hub section unavailable without invalidating the key. A permission error requires a replacement key with that feature's scopes; an expired or revoked key also needs replacement.

These permissions were matched against Enve's current queries and mutations and Hardcover's [published operation-to-scope mapping](https://github.com/hardcoverapp/hardcover-docs/blob/main/capability-scopes.json) on October 27, 2026. Hardcover's [getting-started guide](https://docs.hardcover.app/api/getting-started) explains key creation and expiry. A live restricted-key check remains part of integration verification.
