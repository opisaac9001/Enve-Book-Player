# Grimmory Companion App: Master API Reference

This document maps out the specific API endpoints required to build a fully-featured mobile companion application (supporting both Ebooks and Audiobooks) that connects to the Grimmory server.

> **Auth Note:** All endpoints require an `Authorization: Bearer <JWT>` header, except for media stream endpoints (like audiobook streams or EPUB file fetches) which can alternatively accept a `?token=<JWT>` query parameter.

---

## 1. Authentication
* **Login**: `POST /api/v1/auth/login`
  * Body: `{"username": "...", "password": "..."}`
  * Returns: `{"accessToken": "...", "refreshToken": "..."}`

---

## 2. Core Navigation & Libraries
The mobile application interface endpoints are scoped under `/api/v1/app/*`.

* **List Libraries**: `GET /api/v1/app/libraries`
  * Returns: Standardized `AppLibrarySummary` objects, localized by user permissions.
* **List User Shelves**: `GET /api/v1/app/shelves`
* **List Magic Shelves**: `GET /api/v1/app/shelves/magic`
* **List Series**: `GET /api/v1/app/series?page=0&size=20&sort=recentlyAdded`
* **List Authors**: `GET /api/v1/app/authors?page=0&size=30&sort=name`

---

## 3. Book Feeds & Discovery
* **Main Book List**: `GET /api/v1/app/books?page=0&size=50`
  * Query Params: `libraryId`, `shelfId`, `status`, `search`, `fileType`, `minRating`, `maxRating`, `authors`, `language`.
* **Book Details**: `GET /api/v1/app/books/{bookId}`
* **Search**: `GET /api/v1/app/books/search?q={query}`
* **Curated Feeds**:
  * Home "Continue Reading": `GET /api/v1/app/books/continue-reading?limit=10`
  * Home "Continue Listening": `GET /api/v1/app/books/continue-listening?limit=10`
  * "Recently Added": `GET /api/v1/app/books/recently-added?limit=10`
  * "Discover Random": `GET /api/v1/app/books/random?limit=20`

---

## 4. Library Interactions
Allowing the user to interact with their books from the app interface.
* **Update Read Status**: `PUT /api/v1/app/books/{bookId}/status`
  * Body: `{"status": "READING" | "COMPLETED" | "PAUSED" | "ABANDONED" | "WONT_READ"}`
* **Update Rating**: `PUT /api/v1/app/books/{bookId}/rating`
  * Body: `{"rating": 5}` (Integer 1-5)

---

## 5. Audiobook Playback Engine
* **Get Audiobook Info & Chapters**: `GET /api/v1/audiobooks/{bookId}/info`
  * Returns chapter data, track layout, and absolute durations.
* **Stream Entire Audiobook**: `GET /api/v1/audiobooks/{bookId}/stream` (Supports HTTP Range Requests)
* **Stream Specific Track** (For Multi-File M4B/MP3s): `GET /api/v1/audiobooks/{bookId}/track/{index}/stream`
* **Fetch Embedded MP3 Metadata Cover**: `GET /api/v1/audiobooks/{bookId}/cover`

---

## 6. Ebook Reading Engine
* **Get EPUB Metadata / Spine / TOC**: `GET /api/v1/epub/{bookId}/info`
* **Stream Internal EPUB File** (HTML/CSS/Fonts): `GET /api/v1/epub/{bookId}/file/{path}`
  * Note: The `path` is the internal archive path (e.g. `OEBPS/Text/chapter1.html`).

---

## 7. Progress Sync (Telemetry)
* **Record Single Session**: `POST /api/v1/reading-sessions`
  * Required Body:
    ```json
    {
      "bookId": 123,
      "bookType": "EPUB", 
      "startTime": "2026-03-26T20:00:00Z",
      "endTime": "2026-03-26T20:15:00Z",
      "durationSeconds": 900
    }
    ```
* **Fetch Session History**: `GET /api/v1/reading-sessions/book/{bookId}`

---

## 8. Media & Image Assets
These endpoints stream raw binary image data (JPEG/PNG/WEBP).

* **Book Thumbnail (Portrait)**: `GET /api/v1/media/book/{bookId}/thumbnail`
* **Book High-Res Cover**: `GET /api/v1/media/book/{bookId}/cover`
* **Audiobook Thumbnail (Square)**: `GET /api/v1/media/book/{bookId}/audiobook-thumbnail`
* **Audiobook High-Res Cover**: `GET /api/v1/media/book/{bookId}/audiobook-cover`
* **Author Headshot Thumbnail**: `GET /api/v1/media/author/{authorId}/thumbnail`
* **Author High-Res Photo**: `GET /api/v1/media/author/{authorId}/photo`

---

## 📓 9. Notebooks & Annotations
* **List Annotated Books**: `GET /api/v1/app/notebook/books`
* **Get Highlights/Bookmarks for Book**: `GET /api/v1/app/notebook/books/{bookId}/entries`
* **Update Entry**: `PUT /api/v1/app/notebook/entries/{entryId}?type={type}`
* **Delete Entry**: `DELETE /api/v1/app/notebook/entries/{entryId}?type={type}`
