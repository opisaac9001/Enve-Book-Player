# Building a Third-Party Companion App for Grimmory

This guide documents the request lifecycle and payloads used by third-party Grimmory clients.

---

## 🚀 1. Authentication (Login Flow)
Before your app can do anything, it must exchange user credentials for a JWT (JSON Web Token). This token must be included as an `Authorization: Bearer <TOKEN>` header on **all subsequent requests.**

### Request
```bash
POST /api/v1/auth/login
Content-Type: application/json

{
  "username": "<username>",
  "password": "<password>"
}
```

### Response Example
```json
{
  "isDefaultPassword": "false",
  "refreshToken": "<refresh-token>",
  "accessToken": "<access-token>"
}
```
**Developer Note:** Store both tokens securely. When the `accessToken` expires (usually indicated by a `401 Unauthorized` response to your API calls), use the refreshToken against `/api/v1/auth/refresh` to get a new session seamlessly without making the user re-type their password.

---

## 📚 2. Connecting to the Library
Once authenticated, the home screen of your app should likely query the libraries assigned to the user. A Grimmory server can host multiple libraries (e.g. "Audiobooks", "Ebooks", "Manga").

### Request
```bash
GET /api/v1/app/libraries
Authorization: Bearer <accessToken>
```

### Response Example
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

---

## 📖 3. Fetching the Book Feed
Now that you have the `libraryId` (e.g., `3`), you can fetch a paginated list of books to display in your UI. This endpoint powers the main feed.

### Request
```bash
GET /api/v1/app/books?page=0&size=20&sort=addedOn,desc&libraryId=3
Authorization: Bearer <accessToken>
```

### Response Example
```json
{
  "content": [
    {
      "id": 99,
      "title": "Spellmonger",
      "authors": [
        "Terry Mancour"
      ],
      "thumbnailUrl": "/api/books/99/cover",
      "readStatus": "READING",
      "seriesNumber": 1.0,
      "libraryId": 3,
      "addedOn": "2026-03-21T03:13:41Z",
      "lastReadTime": "2026-03-25T05:53:48Z",
      "primaryFileType": "AUDIOBOOK",
      "audiobookCoverUpdatedOn": "2026-03-21T03:13:41Z",
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
**Developer Note:** The `primaryFileType` indicates how your client should open the file (`AUDIOBOOK` triggers the audio player view, while `EPUB` triggers the Epub.js reader surface).

---

## 🖼️ 4. Loading Media (Images & Audio)
To display the cover image, you can use the `thumbnailUrl` provided in the book feed, OR construct the GET request directly.

However, standard standard HTML `<img>` tags or Mobile WebViews don't easily allow you to pass the `Authorization` header. To solve this, Grimmory allows passing the token as a query parameter for streaming or image loading!

* **Load Cover:** `<img src="http://SERVER/api/v1/books/99/cover?token=<accessToken>" />`
* **Stream Audio Track:** `<audio src="http://SERVER/api/v1/audiobooks/99/stream?token=<accessToken>" />` 

---

## 🏷️ 5. Fetching Shelves and Magic Shelves
Users organize their books into custom collections. Standard Shelves are manually curated, while Magic Shelves use dynamic search filters (like "All books by Stephen King"). Here's how you populate the "Shelves" tab.

### Request
```bash
GET /api/v1/app/shelves
Authorization: Bearer <accessToken>
```

### Response Example
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
*(To get books specifically inside this shelf, you'd call `GET /api/v1/app/shelves/1/books`)*

---

## ⏱️ 6. Tracking Reading Progress & Session Telemetry
When the user is actively listening or reading your app, you should periodically sync their progress to the server. This populates their global Reading Stats (Heatmaps, Streaks) and syncs position across devices.

### Request
Every minute (or upon closing the app), POST to the Reading Session endpoint.
```bash
POST /api/v1/reading-sessions
Content-Type: application/json
Authorization: Bearer <accessToken>

{
  "bookId": 99,
  "bookType": "AUDIOBOOK",
  "startTime": "2026-03-26T20:40:00Z",
  "endTime": "2026-03-26T20:45:00Z",
  "durationSeconds": 300
}
```
At the same time, push the absolute file progress so other devices know exactly what second or page the user left off on.
```bash
POST /api/v1/books/progress
Content-Type: application/json
Authorization: Bearer <accessToken>

{
  "bookId": 99,
  "bookType": "AUDIOBOOK",
  "progressPercentage": 12.5,
  "lastProgress": "450" 
}
```
*(Note: `lastProgress` is the absolute position—for Audiobooks it's the timestamp in seconds, and for EPUBS it represents the CFI / pagination locator).*
