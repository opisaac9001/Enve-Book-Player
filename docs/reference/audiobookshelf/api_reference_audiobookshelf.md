# Audiobookshelf API Reference (Syncing & Bookmarks)

This document maps out the essential API endpoints for Audiobookshelf required for synchronizing library state, user progress, and bookmarks (annotations). It is base on reverse-engineering of the official iOS app (`audiobookshelf-app-master`) and the `AudioBooth` third-party client.

Unless otherwise specified, all API calls are made under the `/api/` prefix (e.g., `http://your-server/audiobookshelf/api/`).

---

## 1. Authentication & Security

### Log In
`POST /login`

Used to obtain initial session and refresh tokens.

**Headers:**
```http
Content-Type: application/json
x-return-tokens: true
```

**Request Body:**
```json
{
  "username": "YourUsername",
  "password": "YourPassword"
}
```

**Response Example:**
```json
{
  "user": {
    "id": "user_uuid",
    "username": "root",
    "token": "LEGACY_TOKEN",
    "accessToken": "JWT_ACCESS_TOKEN",
    "refreshToken": "JWT_REFRESH_TOKEN",
    "mediaProgress": [...],
    "bookmarks": [...]
  }
}
```

### Token Refresh
`POST /auth/refresh`

Audiobookshelf uses short-lived JWT access tokens. If a request returns `401 Unauthorized`, the client should attempt to refresh the token.

**Headers:**
```http
x-refresh-token: YOUR_REFRESH_TOKEN
```

---

## 2. Global Synchronization

### Fetch User Data (Sync All)
`GET /api/me`

This is the primary endpoint for broad synchronization. It returns the current user's profile, including all active progress markers and bookmarks.

**Response Details:**
- `mediaProgress`: An array of objects tracking current position and "finished" status for all items.
- `bookmarks`: An array of all user-created timestamps and notes.

---

## 3. Bookmarks & Annotations

In Audiobookshelf, **annotations** are implemented as the `title` field within a **bookmark** object.

### Create/Upsert Bookmark
`POST /api/me/item/{libraryItemId}/bookmark`

**Request Body:**
```json
{
  "time": 30750.5,
  "title": "A note about this scene"
}
```

**Response Example:**
```json
{
  "libraryItemId": "ae0bcaf4-...",
  "time": 30750.5,
  "title": "A note about this scene",
  "createdAt": 1775262587847
}
```

### Update Bookmark (Edit Annotation)
`PATCH /api/me/item/{libraryItemId}/bookmark`

Used to modify the title/note of an existing bookmark at a specific timestamp.

### Delete Bookmark
`DELETE /api/me/item/{libraryItemId}/bookmark/{time}`

---

## 4. Playback Progress (Media & Ebook)

### Direct Progress Update
`PATCH /api/me/progress/{libraryItemId}`

Updates the user's position for a specific library item.

**Request Body (Audiobook):**
```json
{
  "currentTime": 1234.56,
  "isFinished": false
}
```

**Request Body (Ebook):**
```json
{
  "ebookProgress": 0.45,
  "ebookLocation": "epubcfi(/6/4[chap1]...)"
}
```

---

## 5. The "Sync Heartbeat" Protocol

The official Audiobookshelf app implements a robust periodic sync to handle real-time progress tracking and multi-device resume.

### Sync Session (Periodic Heartbeat)
`POST /api/session/{sessionId}/sync`

> [!IMPORTANT]
> **Implementation Rule**: This heartbeat should be sent every **15 seconds** during active playback. If the device is in Low Power Mode, the interval should be increased to **60 seconds**.

**Request Body:**
```json
{
  "timeListened": 15.0,
  "currentTime": 1249.56
}
```

**Logic Requirements:**
1.  **`timeListened`**: This must represent the amount of time (in milliseconds or seconds depending on implementation, usually milliseconds in raw logs) played *since the last successful sync*.
2.  **State Reset**: You must reset the local "time listened" counter to 0 **only after** receiving a successful `200 OK` response from the server. This ensures that no playback time is lost due to network errors.

---

## 6. Offline & Session Life Cycle

### Start Play Session
`POST /api/items/{libraryItemId}/play`

Requests the server to initialize a playback session, which generates a `sessionId` required for heartbeat syncing.

### Bulk Offline Sync
`POST /api/session/local-all`

Used to push multiple playback sessions that occurred while the device was offline. This is critical for mobile applications.

### Close Session
`POST /api/session/{sessionId}/close`

Notifies the server that playback has stopped cleanly.

---

## Appendix: Verified Case Study (AudioBooth & Official App)

- **AudioBooth**: Uses `SessionService.swift` to manage the `/api/session/local` and `/api/session/local-all` flows, ensuring that offline listening sessions are reconciled when the app reconnects.
- **Official App**: Uses `PlayerProgress.swift` as a centralized coordinator for the 15-second heartbeat, strictly enforcing that `timeListened` is a "delta" rather than a cumulative total.
