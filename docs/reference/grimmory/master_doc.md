# Grimmory Master API Documentation

This document compiles the reverse-engineered API endpoints from the remainder of the Grimmory backend services. These cover third-party syncing, external tool integrations, OPDS feeds, custom metadata shelves, and direct document access. 

> **Authentication:** Most endpoints below require `Authorization: Bearer <TOKEN>`. 
> [!IMPORTANT]
> **Media & Streaming**: Endpoints for covers, thumbnails, and audio streams **require** `?token=<TOKEN>` as a query parameter. They currently reject the Bearer token in the header.

## 🗂️ 1. Shelves & Organization
### Standard Shelves
* **List Shelves:** `GET /api/v1/shelves`
* **Create Shelf:** `POST /api/v1/shelves`
* **Update Shelf:** `PUT /api/v1/shelves/{id}`
* **Delete Shelf:** `DELETE /api/v1/shelves/{id}`
* **Get Shelf Books:** `GET /api/v1/shelves/{id}/books`

### Magic Shelves (Dynamic Filters)
* **List Magic Shelves:** `GET /api/magic-shelves`
* **Create/Update Magic Shelf:** `POST /api/magic-shelves`
  * Payload contains a dynamic `filterJson` string to dynamically pull books.
* **Delete Magic Shelf:** `DELETE /api/magic-shelves/{id}`

---

## ⚡ 2. Book & Author Core 
### Books
* **Get Books:** `GET /api/v1/books`
* **Download Book ZIP/File:** `GET /api/v1/books/{id}/download-all`
* **Stream Book File Bytes:** `GET /api/v1/books/{id}/content`
* **Get Ebook Cover:** `GET /api/v1/media/book/{id}/cover`
* **Get Audiobook Cover:** `GET /api/v1/media/book/{id}/audiobook-cover`
* **Toggle Physical Status:** `PATCH /api/v1/books/{id}/physical`
* **Scan for Duplicates:** `POST /api/v1/books/duplicates`
* **Book Recommendations:** `GET /api/v1/books/{id}/recommendations`

### Authors
* **List All Authors:** `GET /api/v1/authors`
* **Download Author Photo:** `POST /api/v1/authors/{id}/photo/upload`
* **External Scraper Match:** `POST /api/v1/authors/{id}/search-metadata`
* **Auto-Match Authors:** `POST /api/v1/authors/auto-match`

---

## 📡 3. OPDS Integrations
OPDS catalog endpoints for use with standard E-reader software (Moon+ Reader, FBReader, etc).

* **Root Navigation Feed:** `GET /api/v1/opds`
* **Libraries Navigation:** `GET /api/v1/opds/libraries`
* **Shelves Navigation:** `GET /api/v1/opds/shelves`
* **Acquisition/Catalog:** `GET /api/v1/opds/catalog`
* **Recent Books:** `GET /api/v1/opds/recent`
* **OpenSearch Definition:** `GET /api/v1/opds/search.opds`

---

## 🔄 4. External Hardware Syncing (Koreader, Kobo, Komga)
### Koreader
* **Authorize:** `GET /api/koreader/users/auth`
* **Get Progress:** `GET /api/koreader/syncs/progress/{bookHash}`
* **Push Progress:** `PUT /api/koreader/syncs/progress`

### Kobo E-Readers
* **Initialize Device:** `GET /api/kobo/{token}/v1/initialization`
* **Authenticate Device:** `POST /api/kobo/{token}/v1/auth/device`
* **Sync Library Updates:** `GET /api/kobo/{token}/v1/library/sync`
* **Push Reading State:** `PUT /api/kobo/{token}/v1/library/{bookId}/state`
* **Download Book to Kobo:** `GET /api/kobo/{token}/v1/books/{bookId}/download`

### Komga API (Comic Reader Emulation)
* **List Libraries:** `GET /komga/api/v1/libraries`
* **List Series:** `GET /komga/api/v1/series`
* **List Books:** `GET /komga/api/v1/books`
* **Get Page Image:** `GET /komga/api/v1/books/{bookId}/pages/{pageNumber}`

---

## ☁️ 5. Social & Tool Integrations
### Hardcover & Bookdrop
* **Get Hardcover Settings:** `GET /api/v1/hardcover-sync-settings`
* **List Bookdrop Imports:** `GET /api/v1/bookdrop/files`
* **Extract Metadata from Pattern:** `POST /api/v1/bookdrop/files/extract-pattern`
* **Finalize Imports:** `POST /api/v1/bookdrop/imports/finalize`

### Annotations & Reviews
* **Create Annotation:** `POST /api/v1/annotations`
* **Get Book Annotations:** `GET /api/v1/annotations/book/{bookId}`
* **List Reviews:** `GET /api/v1/reviews/book/{bookId}`
* **Refresh GoodReads/Hardcover Reviews:** `POST /api/v1/reviews/book/{bookId}/refresh`
