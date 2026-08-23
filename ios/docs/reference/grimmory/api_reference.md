Unless otherwise specified, pass your JWT token via the HTTP header `Authorization: Bearer <token>`. 

> [!IMPORTANT]
> **Media Authentication**: Media streaming and image endpoints (covers, thumbnails, audio streams) **require** the token to be passed as a query parameter (e.g. `?token=<token>`). These endpoints currently reject the Bearer token in the header with a 401 Unauthorized status.


## 1. Authentication & Basic Flow

Before executing any other commands, you must authenticate to retrieve session tokens.

### Log In
`POST /api/v1/auth/login`

**Request Object:**
```json
{
  "username": "YourUsername",
  "password": "YourPassword"
}
```

**Response Details:**
```json
{
  "isDefaultPassword": "false",
  "accessToken": "eyJhbGciOi...",
  "refreshToken": "eyJhbGciOi..."
}
```
Store these tokens. Send the `accessToken` in your Auth header. Once the `accessToken` expires (triggering HTTP 401 errors), use the `refreshToken` against `/api/v1/auth/refresh` to request a new session without prompting the user.

### Fetch Available Libraries
`GET /api/v1/app/libraries`

> [!WARNING]
> **Endpoint Stability**: This endpoint (and others under `/api/v1/app/`) currently returns a **500 Internal Server Error** on some server versions (including nightly build `20260405`). Use `GET /api/v1/libraries` as a reliable alternative for retrieving library metadata.

**Response Example:**
```json
[
  {
    "id": 2,
    "name": "Test Books",
    "bookCount": 36,
    "allowedFormats": [],
    "paths": [
      {
        "id": 2,
        "path": "/books/Books"
      }
    ]
  },
  {
    "id": 3,
    "name": "Test spell",
    "bookCount": 28,
    "allowedFormats": [],
    "paths": [
      {
        "id": 3,
        "path": "/books/audiobooks/library/Terry Mancour"
      }
    ]
  }
]
```
Use this near the start of the app session. It returns the content folders (audiobooks, PDFs, ebooks) currently assigned to the user profile. 

> [!NOTE]
> **Server-Side Paths**: The `paths` array contains the absolute root mount points on the Grimmory server (e.g., `/books/Books`). Client applications that support direct network access (SMB/WebDAV) use these roots to map server-side file paths to local network mounts.


### Fetch Book Feeds
`GET /api/v1/app/books?page=0&size=20&sort=addedOn,desc&libraryId=x`

> [!WARNING]
> Grimmory plans to deprecate the `/api/v1/app/` surface. Current Enve releases still use this feed when available and fall back to `GET /api/v1/books`; do not migrate more catalog reads until the stable replacement has equivalent paging, progress, file, and metadata coverage.

**Response Example:**
```json
{
  "content": [
    {
      "id": 99,
      "title": "Spellmonger",
      "authors": ["Terry Mancour"],
      "thumbnailUrl": "/api/books/99/cover",
      "readStatus": "READING",
      "seriesNumber": 1.0,
      "libraryId": 3,
      "addedOn": "2026-03-21T03:13:41Z",
      "lastReadTime": "2026-03-25T05:53:48Z",
      "primaryFileType": "AUDIOBOOK",
      "primaryFileName": "Marshal Arcane.m4b",
      "audiobookCoverUpdatedOn": "2026-03-21T03:13:41Z",
      "publisher": "Podium Audio",
      "categories": ["Fantasy"],
      "language": "en",
      "narrator": "John Lee",
      "isbn13": "9781039414723",
      "isPhysical": false
    }
  ],
  "page": 0,
  "size": 1,
  "totalElements": 64,
  "totalPages": 64,
  "hasNext": true,
  "hasPrevious": false
}
```
Pulls a paginated list of items from a specific library. 

> [!IMPORTANT]
> **Audiobook title contract:** `title` is Grimmory's editable book metadata and can be wrong for an entire imported series. The verified test library returned `title: "Spellmonger"` for distinct books whose `primaryFileName` values were `Marshal Arcane.m4b`, `Enchanter.m4b`, and others. For audiobooks, Enve must use the extension-stripped `primaryFileName` as the display title and fall back to `title` only when the filename is absent. `GET /api/v1/app/books/{id}` exposes the same filename through the primary entry in `files`.

The summary response already carries narrator, publisher, categories, language, ISBN, page count, and ratings. Clients should map these fields directly. Fetch `GET /api/v1/app/books/{id}` plus `GET /api/v1/audiobooks/{id}/info` when full description, duration, chapters, tracks, or progress-position detail is required.

### Fetch App Authors
`GET /api/v1/app/authors?page=0&size=20`

**Response Example:**
```json
{
  "content": [
    {
      "id": 16,
      "name": "Francois Voltaire",
      "asin": "B000APWM7O",
      "bookCount": 3,
      "hasPhoto": false
    }
  ],
  "page": 0,
  "size": 1,
  "totalElements": 28,
  "totalPages": 28,
  "hasNext": true,
  "hasPrevious": false
}
```

### Fetch App Series
`GET /api/v1/app/series?page=0&size=20`

**Response Example:**
```json
{
  "content": [
    {
      "seriesName": "Spellmonger Universe",
      "bookCount": 2,
      "seriesTotal": 53,
      "authors": ["Terry Mancour"],
      "booksRead": 0,
      "latestAddedOn": "2026-03-21T03:13:38Z",
      "coverBooks": [
        { "bookId": 80, "seriesNumber": 1.0, "primaryFileType": "AUDIOBOOK" }
      ]
    }
  ],
  "page": 0,
  "size": 1,
  "totalElements": 7,
  "totalPages": 7,
  "hasNext": true,
  "hasPrevious": false
}
```

### Fetch App Shelves
`GET /api/v1/app/shelves`

**Response Example:**
```json
[
  {
    "id": 1,
    "name": "Favorites",
    "icon": "heart",
    "bookCount": 0,
    "publicShelf": false
  }
]
```


## 2. Core Book & Author Queries

### Books
*   `GET /api/v1/books` - Master list of all books in the database.

**Response Example:**
```json
[
  {
    "addedOn": "2026-03-21T03:11:09Z",
    "id": 37,
    "isPhysical": false,
    "libraryId": 2,
    "libraryName": "Test Books",
    "metadata": {
      "bookId": 37,
      "title": "Pocket Philosophical Dictionary",
      "publisher": "Oxford University Press",
      "publishedDate": "2025-08-05",
      "language": "en",
      "coverUpdatedOn": "2026-03-21T03:11:10Z",
      "authors": [
        "Voltaire; Fletcher, John; Cronk, Nicholas"
      ],
      "allMetadataLocked": false
    },
    "metadataMatchScore": 37.234,
    "primaryFile": {
      "addedOn": "2026-03-21T03:11:09Z",
      "book": true,
      "bookId": 37,
      "bookType": "EPUB",
      "extension": "epub",
      "fileName": "Voltaire - A Pocket Philosophical Dictionary [tr. Fletcher] (Oxford, 2011).epub",
      "filePath": "/books/Books/Voltaire - Collected Philosophical Works, incl. Candide (34 books)/Voltaire - A Pocket Philosophical Dictionary [tr. Fletcher] (Oxford, 2011).epub",
      "fileSizeKb": 2339,
      "fileSubPath": "Voltaire - Collected Philosophical Works, incl. Candide (34 books)",
      "folderBased": false,
      "id": 37
    }
  },
  {
    "addedOn": "2026-03-21T03:11:11Z",
    "id": 38,
    "isPhysical": false,
    "libraryId": 2,
    "libraryName": "Test Books",
    "metadata": {
      "bookId": 38,
      "title": "A Pocket Philosophical Dictionary",
      "publishedDate": "2025-08-06",
      "pageCount": 322,
      "coverUpdatedOn": "2026-03-21T03:11:13Z",
      "authors": [
        "Voltaire / John Fletcher [translator] / Nicholas Cronk [Introduction and Notes]"
      ],
      "categories": [
        "ST / CS"
      ],
      "allMetadataLocked": false
    },
    "metadataMatchScore": 41.4894,
    "primaryFile": {
      "addedOn": "2026-03-21T03:11:11Z",
      "bookId": 38,
      "bookType": "PDF",
      "extension": "pdf",
      "fileName": "Voltaire - A Pocket Philosophical Dictionary [tr. Fletcher] (Oxford, 2011).pdf",
      "filePath": "/books/Books/Voltaire - Collected Philosophical Works, incl. Candide (34 books)/Voltaire - A Pocket Philosophical Dictionary [tr. Fletcher] (Oxford, 2011).pdf",
      "fileSizeKb": 6185,
      "fileSubPath": "Voltaire - Collected Philosophical Works, incl. Candide (34 books)",
      "folderBased": false,
      "id": 38
    }
  }
]
```

#### Key File Fields:
*   **`filePath`**: The absolute path on the Grimmory server. (e.g., `/books/Books/Author/Title.epub`)
*   **`fileSubPath`**: The relative path from the library's root mount point. Useful for mapping between server-side and local/network paths.

*   `GET /api/v1/books/{id}` - Details for a single stored book.
*   `GET /api/v1/books/{id}/download-all` - Archive download of all associated files for a book id.
*   `GET /api/v1/books/{id}/content` - Standard byte stream of local file.
*   `GET /api/v1/books/{id}/recommendations` - Returns similar books in the database.
*   `PATCH /api/v1/books/{id}/physical` - Toggle whether a book is marked as a physical copy.
*   `POST /api/v1/books/duplicates` - Scan the filesystem for duplicate instances.

### Authors
*   `GET /api/v1/authors` - Index of recognized authors.

**Response Example:**
```json
[
  {
    "id": 16,
    "name": "Francois Voltaire",
    "asin": "B000APWM7O",
    "bookCount": 3,
    "hasPhoto": false
  },
  {
    "id": 27,
    "name": "G.K. Noyer",
    "bookCount": 1,
    "hasPhoto": false
  }
]
```
*   `POST /api/v1/authors/{id}/photo/upload` - Manually push a portrait image.
*   `POST /api/v1/authors/auto-match` - Trigger automatic scraping to assign external IDs or photos to local strings.
*   `POST /api/v1/authors/{id}/search-metadata` - Trigger a focused manual metadata match for an individual author.


## 3. Playback and Media

Instead of pulling the file locally, stream it in chunks via HTTP Range headers natively supported by Grimmory.

### Audiobooks
*   `GET /api/v1/audiobooks/{id}/info` - Get chapter layouts, metadata, and absolute duration.
*   `GET /api/v1/audiobooks/{id}/stream` - Directly buffer the audio file.
*   `GET /api/v1/audiobooks/{id}/track/{index}/stream` - Directly buffer a specific track in a multi-file audiobook.
*   `GET /api/v1/audiobooks/{id}/cover` - Extract the ID3/MP3 embedded cover art.

### Ebooks
*   `GET /api/v1/epub/{id}/info` - Parse the NCX or spine of the epub format.
*   `GET /api/v1/epub/{id}/file/{internal_path}` - Load an internal archive file directly (e.g. `OEBPS/Text/chapter1.html`).

### Covers & Author Photos
These endpoints output binary image data (JPEG). 

> [!IMPORTANT]
> **Authentication**: These endpoints **only** accept `?token=<token>` query parameters. 
> **Content-Type Bug**: The server currently returns `Content-Type: application/json` for these images. Most browsers/clients will still render the image if they perform content sniffing.

*   **Ebook (Standard)**:
    *   `GET /api/v1/media/book/{id}/thumbnail`
    *   `GET /api/v1/media/book/{id}/cover`
*   **Audiobook Specific**:
    *   `GET /api/v1/media/book/{id}/audiobook-thumbnail`
    *   `GET /api/v1/media/book/{id}/audiobook-cover`
*   **Authors**:
    *   `GET /api/v1/media/author/{id}/thumbnail`
    *   `GET /api/v1/media/author/{id}/photo`

> [!NOTE]
> If an audiobook ID is used with the standard `/cover` endpoint (or vice versa), the server will return a generic **"MISSING BOOK COVER"** placeholder image rather than an error.


## 4. Reading Telemetry & Syncing

For accurate server statistics, sync your playback progress routinely (e.g., every 60 seconds or on UI close). This involves two actions.

### 1. The Reading Session
Tracks the time spent continuously engaged with a file.
`POST /api/v1/reading-sessions`

**Request:**
```json
{
  "bookId": 99,
  "bookType": "AUDIOBOOK",
  "startTime": "2026-03-26T20:40:00Z",
  "endTime": "2026-03-26T20:45:00Z",
  "durationSeconds": 300
}
```

### 2. The Absolute Progress Marker
Updates the global pointer indicating exactly where the user is within the book.
`POST /api/v1/books/progress`

**Request:**
```json
{
  "bookId": 99,
  "bookType": "AUDIOBOOK",
  "progressPercentage": 12.5,
  "lastProgress": "450" 
}
```
`lastProgress` is measured in absolute seconds (for audiobooks) or CFI string (for EPUBs).


## 5. Player Stats & History 

All user telemetry is queried from `/api/v1/user-stats`.

### General Stats
*   `GET /api/v1/user-stats/reading/streak` - Current daily tracking streak parameters.

**Response Example:**
```json
{
  "currentStreak": 7,
  "longestStreak": 7,
  "totalReadingDays": 7,
  "last52Weeks": [
    {
      "date": "2025-03-27",
      "active": false
    },
    {
      "date": "2025-03-28",
      "active": false
    }
  ]
}
```
*   `GET /api/v1/user-stats/reading/book-distributions` - Counts against star ratings, reading states, and categorical brackets.

**Response Example:**
```json
{
  "ratingDistribution": [],
  "progressDistribution": [
    {
      "range": "Not Started",
      "min": 0,
      "max": 0,
      "count": 6
    },
    {
      "range": "Just Started",
      "min": 1,
      "max": 25,
      "count": 0
    }
  ],
  "statusDistribution": [
    {
      "status": "ABANDONED",
      "count": 3
    },
    {
      "status": "READ",
      "count": 1
    }
  ]
}
```
*   `GET /api/v1/user-stats/reading/heatmap?year=2026` - Array counting activity by day over a calendar year.
*   `GET /api/v1/user-stats/reading/timeline?year=2026&week=13` - Activity grouped by individual book across a specified week format.
*   `GET /api/v1/user-stats/reading/session-scatter?year=2026` - Daily coordinates used for time-of-day scatter graphs.
*   `GET /api/v1/user-stats/reading/page-turner-scores` - Analytics denoting reading pace and acceleration.
*   `GET /api/v1/user-stats/reading/completion-race?year=2026` - Snapshots indexing completion velocity against previous milestones.

### Audiobook Specific Stats
*   `GET /api/v1/user-stats/listening/completion` - Listening completion rates vs total audiobooks.

**Response Example:**
```json
{
  "totalAudiobooks": 2,
  "completed": 2,
  "inProgressCount": 0,
  "inProgress": []
}
```
*   `GET /api/v1/user-stats/listening/heatmap/monthly?year=2026&month=3` - Monthly drill-downs for audio session metrics.
*   `GET /api/v1/user-stats/listening/weekly-trend?weeks=26` - Trailing output of weekly session durations.
*   `GET /api/v1/user-stats/listening/finish-funnel` - Array of retention rates through 25%, 50%, 75% benchmarks.


## 6. Shelves and Organization

### Standard Shelves
*   `GET /api/v1/shelves`
*   `POST /api/v1/shelves`
*   `PUT /api/v1/shelves/{id}`
*   `DELETE /api/v1/shelves/{id}`
*   `GET /api/v1/shelves/{id}/books`

### Magic Shelves
Magic shelves evaluate dynamically against queries rather than storing absolute IDs.
*   `GET /api/magic-shelves`

**Response Example:**
```json
[
  {
    "filterJson": "{\"join\":\"and\",\"rules\":[{\"field\":\"authors\",\"operator\":\"contains\",\"value\":\"Mancour\",\"type\":\"rule\"}],\"type\":\"group\"}",
    "icon": null,
    "iconType": null,
    "id": 1,
    "isPublic": false,
    "name": "Fanasy"
  }
]
```
*   `POST /api/magic-shelves` - Push a `filterJson` query payload to set rules.
*   `DELETE /api/magic-shelves/{id}`


## 7. External Integrations 

### Hardware Sync
*   **KoReader:** `GET /api/koreader/users/auth` (Authorize), `GET /api/koreader/syncs/progress/{hash}`, `PUT /api/koreader/syncs/progress`.
*   **Kobo:** Devices use token paths rather than headers. `GET /api/kobo/{token}/v1/initialization`, `POST /api/kobo/{token}/v1/auth/device`, `GET /api/kobo/{token}/v1/library/sync`. `PUT /api/kobo/{token}/v1/library/{id}/state` pushes progress.
*   **Komga Emulation:** `GET /komga/api/v1/libraries`, `/series`, `/books`, and `/books/{id}/pages/{page}` act as a drop-in Komga replacement for comic readers like Tachiyomi.

### External Scrapers & Notes
*   **OPDS Catalog Support:** Handled under `/api/v1/opds`. Supported routes: root, `/libraries`, `/shelves`, `/catalog`, `/recent`, `/search.opds`.
    * *Note on OPDS Auth: OPDS readers use Basic Auth. You must provision dedicated OPDS users via:*
    * `GET /api/v2/opds-users` - List all OPDS users.
    * `POST /api/v2/opds-users` - Create a new OPDS user.
    * `PATCH /api/v2/opds-users/{id}` - Update OPDS user settings.
    * `DELETE /api/v2/opds-users/{id}` - Delete OPDS user.
*   **Hardcover:** Settings managed via `GET` / `PUT` on `/api/v1/hardcover-sync-settings`.
*   **Bookdrop Ingest:** Import monitoring configured via `/api/v1/bookdrop/files` and `/api/v1/bookdrop/imports/finalize`.
*   **Annotations:** Highlights and notes are tracked via `GET/POST` at `/api/v1/annotations`. User reviews are polled externally via `POST /api/v1/reviews/book/{id}/refresh`.


## 8. Server Configuration (Admin Only)

The following endpoints require Admin capabilities and handle hardware-level logic.

### Server Maintenance 
*   `GET /api/v1/setup/status` - Initial readiness response.
*   `POST /api/v1/setup` - Claim the first administrator account if unhandled.
*   `GET /api/v1/tasks` - Check the cron scheduler available queues. 

**Response Example:**
```json
[
  {
    "taskType": "REFRESH_LIBRARY_METADATA",
    "name": "Refresh Metadata",
    "description": "Re-reads book information (title, author, cover, etc.) from your files and updates the Booklore database.",
    "parallel": false,
    "async": true,
    "cronSupported": false
  },
  {
    "taskType": "UPDATE_BOOK_RECOMMENDATIONS",
    "name": "Update Book Recommendations",
    "description": "Analyzes your library to generate personalized book recommendations based on the books you own.",
    "parallel": false,
    "async": true,
    "cronSupported": true,
    "cronConfig": {
      "id": 6,
      "taskType": "UPDATE_BOOK_RECOMMENDATIONS",
      "cronExpression": "0 30 1 * * *",
      "enabled": true,
      "createdAt": "2026-03-12T18:27:47",
      "updatedAt": "2026-03-12T18:27:47"
    }
  }
]
```
*   `POST /api/v1/tasks/start` - Send `{ "type": "METADATA_SYNC" }` to manually trigger background queues.
*   `PATCH /api/v1/tasks/{type}/cron` - Overwrite global cron scheduling.
*   `GET /api/v1/settings` & `PUT /api/v1/settings` - Read or write the global parameters table.

**Response Example:**
```json
{
  "defaultMetadataRefreshOptions": {
    "libraryId": null,
    "refreshCovers": false,
    "mergeCategories": true,
    "reviewBeforeApply": false,
    "replaceMode": "REPLACE_MISSING",
    "fieldOptions": {
      "title": { "p1": "Amazon" },
      "subtitle": { "p1": "Amazon" },
      "description": { "p1": "Amazon" },
      "authors": { "p1": "Amazon" },
      "publisher": { "p1": "Amazon" },
      "publishedDate": { "p1": "Amazon" },
      "seriesName": { "p1": "Amazon" },
      "seriesNumber": { "p1": "Amazon" },
      "seriesTotal": { "p1": "Amazon" },
      "isbn13": { "p1": "Amazon" },
      "isbn10": { "p1": "Amazon" },
      "language": { "p1": "Amazon" },
      "categories": { "p1": "Amazon" },
      "cover": { "p1": "Amazon" },
      "pageCount": { "p1": "Amazon" }
    }
  },
  "libraryMetadataRefreshOptions": [],
  "autoBookSearch": false,
  "similarBookRecommendation": true,
  "opdsServerEnabled": true,
  "komgaApiEnabled": false,
  "uploadPattern": "{authors}/<{series}/><{seriesIndex}. >/{title}/{title}< - {authors}>< ({year})>",
  "pdfCacheSizeInMb": 5120,
  "maxFileUploadSizeInMb": 100,
  "remoteAuthEnabled": false,
  "metadataDownloadOnBookdrop": true,
  "oidcEnabled": false,
  "metadataProviderSettings": {
    "amazon": { "enabled": true },
    "audible": null,
    "douban": { "enabled": false },
    "goodReads": { "enabled": true },
    "google": { "enabled": true }
  }
}
```

### User Profiles
*   `POST /api/v1/auth/register` - Create an account.
*   `GET /api/v1/users` - Fetch total accounts index.
*   `PUT /api/v1/users/{id}` - Overwrite permissions levels.
*   `DELETE /api/v1/users/{id}` - Destroy an account.
*   `PUT /api/v1/users/change-user-password` - Overwrite a password.

### Storage Control
*   `POST /api/v1/libraries` - Add a mount/folder.
*   `PUT /api/v1/libraries/{id}/refresh` - Force clear and rescan data directories.
*   `GET /api/v1/libraries/health` - Disk status polling.


## 9. Alternative Reading Engines

### CBX Comics/Manga
*   `GET /api/v1/cbx/{id}/pages` - Returns an array of available page numbers.
*   `GET /api/v1/cbx/{id}/page-info` - Returns layout metadata and dimensions per page.

### PDF Documents
*   `GET /api/v1/pdf/{id}/pages` - Available page array.
*   `GET /api/v1/pdf/{id}/info` - Extracts native table of contents/hierarchical outline.
*   `GET /api/v1/pdf-annotations/book/{id}` - Fetch serialized pdf.js annotation layer data.
*   `PUT /api/v1/pdf-annotations/book/{id}` - Push new pdf.js drawings/highlights.

### V2 Book Notes (CFI-Based)
*   `GET /api/v2/book-notes/book/{id}` - Fetch all note spans.
*   `POST /api/v2/book-notes` - Create a new highlight context string.


## 10. Document & Metadata Tooling

### File Control
*   `POST /api/v1/files/move` - Bulk-move absolute file paths.
*   **`GET /api/v1/books/{id}/files`**: Index supplementary/extra files attached to a book.
**Response Example:**
```json
[
  {
    "id": 99,
    "fileName": "Journeymage.m4b",
    "filePath": "/books/audiobooks/library/Terry Mancour/Spellmonger/Journeymage/Journeymage.m4b",
    "fileSubPath": "Spellmonger/Journeymage",
    "fileSizeKb": 454604,
    "extension": "m4b",
    "bookType": "AUDIOBOOK",
    "isPrimary": true
  }
]
```

*   `POST /api/v1/books/{id}/files` - Upload custom attachments.

### Metadata Control
*   `PUT /api/v1/books/{id}/metadata` - Granular override of titles, authors, descriptions.
*   `PUT /api/v1/books/bulk-edit-metadata` - Apply a single tag/genre/attribute across multiple IDs.
*   `POST /api/v1/books/metadata/isbn-lookup` - Scrape external sources via ISBN match.
*   `GET /api/metadata/tasks/active` - Poll batch-processing background task progress.

### Metadata Sidecars (.json / .opf)
*   `POST /api/v1/books/{id}/sidecar/export` - Write current database record out to a folder JSON.
*   `POST /api/v1/books/{id}/sidecar/import` - Overwrite database record from local JSON.
*   `POST /api/v1/libraries/{id}/sidecar/export-all` - Export the entire library back to disk simultaneously.


## 11. Configuration & Utilities

### Styling Configuration
*   `POST /api/v1/custom-fonts/upload` - Store `.ttf` or `.woff` files for use in the EPUB reader.
*   `GET /api/v1/custom-fonts` - Index user's assigned custom fonts.

### Email Operations (Send to Kindle, etc)
*   `GET /api/v1/email/providers` - Get SMTP configurations.
*   `POST /api/v1/email/providers` - Save a new outbound email configuration.

### System Settings 
*   `GET /api/v1/public-settings` - Lightweight, unauthenticated pull for feature flags like OIDC login.
*   `GET /api/v1/kobo-settings` - Secure endpoints handling the Kobo sync registration token.
*   `GET /api/v1/users/{id}/content-restrictions` - Manage allowed content-ratings per profile.
*   `GET /api/v1/version` - Unauthenticated server runtime version and git commit hash.
*   `GET /api/v1/version/changelog` - Fetches markdown release notes differentiating the local installation from standard.


## 12. Manual Metadata Matching

When the initial import pipeline incorrectly matches a book or author against external databases (like Google Books, Audible, or GoodReads), you can build a matching UI that allows users to manually re-link them.

### Re-matching a Book
1. **Fetch Candidates:** `POST /api/v1/books/{id}/metadata/prospective`
   Send an optional `FetchMetadataRequest` JSON body. You can restrict the scrape to specific `providers` or force exact queries via `isbn`, `asin`, `author`, or `title`. Grimmory will reach out to external providers and stream back a list of candidate `BookMetadata` objects.
2. **Apply the Match:** `PUT /api/v1/books/{id}/metadata`
   Wrap the user's chosen metadata object in a `MetadataUpdateWrapper` to overwrite the current database entry.
   
### Re-matching an Author
1. **Search Profiles:** `GET /api/v1/authors/{id}/search-metadata?q=Author+Name`
   Queries external databases to find potential profile matches, returning an array of IDs and sources (`AuthorSearchResult`).
2. **Apply Profile:** `POST /api/v1/authors/{id}/match`
   Submit an `AuthorMatchRequest` (`{"source": "GOODREADS", "asin": "123456"}`) and the backend will scrape and apply the remote author description, birth date, and links.
3. **Automated Search:** `POST /api/v1/authors/auto-match`
   Pass a JSON array of Author IDs to let the server attempt an unattended best-guess sweep for all listed authors.

### Updating Author Photos
1. **Search Images:** `GET /api/v1/authors/{id}/search-photos?q=Author+Name`
   Performs a DuckDuckGo image proxy search on the backend to avoid CORS restrictions, returning a list of direct image URLs.
2. **Apply Image:** `POST /api/v1/authors/{id}/photo/url?url={extracted_url}`
   The server downloads and permanently saves the chosen image locally as the author's primary portrait.


## 13. Annotations and Bookmarks (Cross-Device Sync)

When a user reads or listens to a book on a client app, their highlights, notes, and bookmarks must be synced back to Grimmory so they can be restored on other devices. Grimmory splits this into three distinct categories based on standard reading app behavior.

### 1. Bookmarks (Generic Placemarkers)
Bookmarks are used to save an exact location without modifying the text. They uniquely support **both Ebooks and Audiobooks**.

*   `GET /api/v1/bookmarks/book/{id}` - Pull down all bookmarks for a specific book.
*   `POST /api/v1/bookmarks` - Upload a new bookmark.

**Ebook (EPUB) Payload:**
```json
{
  "bookId": 99,
  "title": "A cool quote",
  "cfi": "epubcfi(/6/14[xchap04]!/4/2/1:0)",
  "color": "#FFC0CB",
  "notes": "Remember this for later",
  "priority": 1
}
```

**Audiobook Payload:**
```json
{
  "bookId": 99,
  "title": "Favorite Scene",
  "positionMs": 3450000,
  "trackIndex": 1,
  "notes": "The dragon attacks",
  "priority": 1
}
```
*Note: The presence of `positionMs` automatically flags the server to treat it as an Audiobook bookmark, skipping EPUB CFI validation.*

### 2. Annotations (Stylized Text Modifications)
Annotations are for visual page markup (highlights, underlines, squiggly lines) tied directly to a block of highlighted Ebook text.

*   `GET /api/v1/annotations/book/{id}` - Pull down all style markers.
*   `POST /api/v1/annotations` - Create a new highlight/underline.

**Upload Payload:**
```json
{
  "bookId": 99,
  "cfi": "epubcfi(/6/14[xchap04]!/4/10/2/1:10,/1:34)",
  "text": "It was the best of times",
  "color": "#FFFF00",
  "style": "highlight",
  "note": "A classic opening line",
  "chapterTitle": "Chapter 1: The Period"
}
```
*Valid `style` enums:* `highlight`, `underline`, `strikethrough`, `squiggly`.

### 3. Book Notes V2 (Contextual Highlights)
Book Notes V2 (`/api/v2/book-notes`) is a newer endpoint specifically designed for applications that want to build a "Notebook" UI. It acts similarly to Annotations but uses `noteContent` and `selectedText` keys, aimed at exporting user thoughts rather than just rendering colored lines on a page.

*   `GET /api/v2/book-notes/book/{id}` - Pull notebooks.
*   `POST /api/v2/book-notes` - Push a notebook entry.

**Upload Payload:**
```json
{
  "bookId": 99,
  "cfi": "epubcfi(/6/14[xchap04]!/4/10)",
  "selectedText": "Call me Ishmael.",
  "noteContent": "Is this a metaphor?",
  "color": "#00FF00",
  "chapterTitle": "Loomings"
}
```


## 14. Implementation Guide: SMB/Network Mapping

If your client application (like **Enve**) supports direct file access via SMB or WebDAV, you can use the Grimmory API to resolve server-side telemetry to local files.

### Mapping Algorithm:
1.  **Get Library Roots**: Fetch `GET /api/v1/app/libraries`. Note the `path` for the relevant library (e.g., `/books/Books`).
2.  **Get Book Location**: Fetch `GET /api/v1/books/{id}`. Note the `filePath` (e.g., `/books/Books/Classic/Hamlet.pdf`).
3.  **Calculate Relative Path**: The `fileSubPath` is usually the safest way to map, as it represents the structure *within* the share.
4.  **Local Connection**:
    *   If your SMB share is mounted at `smb://NAS/Books` which maps to `/books/Books` on the server.
    *   The local path becomes: `smb://NAS/Books/` + `fileSubPath`.

> [!TIP]
> **Performance**: Use `GET /api/v1/books?size=100` to bulk-fetch file locations during initial library indexing rather than querying individual IDs.
