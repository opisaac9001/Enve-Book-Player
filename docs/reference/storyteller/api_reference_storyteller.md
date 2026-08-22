# Storyteller API Reference

This document outlines the Storyteller backend API endpoints used for building third-party applications or integrating external services. It covers library management, user administration, server configuration, and playback operations.

Unless otherwise specified, all API calls are made under the `/api/v2/` prefix.

## Table of Contents

1. [Authentication](#1-authentication--basic-flow)
2. [Library Queries](#2-core-library-queries)
3. [Collections Management](#3-collections-management)
4. [Playback & Media](#4-playback-and-media)
5. [Book Operations & Lifecycle](#5-book-operations--lifecycle)
6. [Progress & Navigation](#6-progress--navigation)
7. [User Administration](#7-user-administration)
8. [Server Configuration](#8-server-configuration)
9. [System & Real-time Events](#9-system--real-time-events)

---

## 1. Authentication & Basic Flow

Storyteller uses session-based authentication. When a user logs in, the server sets a session cookie named `st_token`. This cookie must be included in all subsequent API requests.

### Log In
`POST /login`

**Request Body (Form Data):**
```http
username=YourUsername&password=YourPassword
```

**Response Details:**
The server responds with a `303 See Other` redirect and sets the `st_token` cookie.
```http
HTTP/1.1 303 See Other
Set-Cookie: st_token=1d0712d2-938b-47af-ae20-3bd77750525d; Path=/; HttpOnly; SameSite=Lax
Location: /
```

### Log Out
`POST /logout`

**Response:**
```http
HTTP/1.1 303 See Other
Set-Cookie: st_token=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT
```

---

## 2. Core Library Queries

### Fetch All Books
`GET /api/v2/books`

**Response Example:**
```json
[
  {
    "uuid": "000387a0-7784-4cf7-9672-2e8cadc725cd",
    "title": "Spellmonger",
    "authors": [
      {
        "uuid": "d2a7255b-661d-4d5f-9ad4-999a073511cf",
        "name": "Terry Mancour"
      }
    ],
    "narrators": [
      {
        "uuid": "baefaa73-8fcf-417c-b7e6-c1288723161b",
        "name": "John Lee"
      }
    ],
    "audiobook": {
      "uuid": "d13346c4-c1cd-4ea9-a5b5-daa6e4352347",
      "filepath": "/data/assets/library/Terry Mancour/Spellmonger/Enchanter"
    },
    "status": {
      "uuid": "6ab3dd21-fc4a-4650-a4d4-beaad22fdd45",
      "name": "To read"
    }
  }
]
```

### Fetch Book Details
`GET /api/v2/books/{uuid}`

**Response Example:**
```json
{
  "uuid": "000387a0-7784-4cf7-9672-2e8cadc725cd",
  "title": "Spellmonger",
  "description": "ISBN: 9781772307986",
  "createdAt": "2026-03-23 06:28:17",
  "authors": [
    {
      "uuid": "d2a7255b-661d-4d5f-9ad4-999a073511cf",
      "name": "Terry Mancour"
    }
  ],
  "narrators": [
    {
      "uuid": "baefaa73-8fcf-417c-b7e6-c1288723161b",
      "name": "John Lee"
    }
  ],
  "status": {
    "uuid": "6ab3dd21-fc4a-4650-a4d4-beaad22fdd45",
    "name": "To read"
  },
  "audiobook": {
    "uuid": "d13346c4-c1cd-4ea9-a5b5-daa6e4352347",
    "filepath": "/data/assets/library/Terry Mancour/Spellmonger/Enchanter"
  }
}
```

### Fetch Creators
`GET /api/v2/creators`
*   **Query Params**: `?role=aut` (authors only), `?role=nar` (narrators only).

**Response Example:**
```json
[
  {
    "uuid": "d2a7255b-661d-4d5f-9ad4-999a073511cf",
    "name": "Terry Mancour",
    "fileAs": "Terry Mancour",
    "createdAt": "2026-03-23 04:41:32"
  }
]
```

### Fetch Tags
`GET /api/v2/tags`

**Response Example:**
```json
[
  {
    "uuid": "f2a7255b-661d-4d5f-9ad4-999a073511cf",
    "name": "Fantasy"
  }
]
```

### Fetch Series
`GET /api/v2/series`

**Response Example:**
```json
[
  {
    "uuid": "e2a7255b-661d-4d5f-9ad4-999a073511cf",
    "name": "Spellmonger Universe",
    "description": "High fantasy series by Terry Mancour"
  }
]
```

---

## 3. Collections Management

### List Collections
`GET /api/v2/collections`

**Response Example:**
```json
[
  {
    "uuid": "da940d66-3580-4111-9ac2-d8ab8578fbae",
    "name": "API Example",
    "public": true,
    "description": ""
  }
]
```

### Create Collection
`POST /api/v2/collections`

**Request Body:**
```json
{
  "name": "Research Test",
  "public": true,
  "description": "API Test Collection",
  "users": [],
  "importPath": null
}
```

**Response Example:**
```json
{
  "uuid": "da940d66-3580-4111-9ac2-d8ab8578fbae",
  "name": "Research Test",
  "public": true,
  "description": "API Test Collection",
  "createdAt": "2026-04-01 23:07:00"
}
```

### Update Collection
`PUT /api/v2/collections/{uuid}`

**Request Body:**
```json
{
  "name": "Research Final",
  "public": true,
  "description": "Updated description"
}
```

### Add Books to Collection
`POST /api/v2/collections/books`

**Request Body:**
```json
{
  "collections": ["da940d66-3580-4111-9ac2-d8ab8578fbae"],
  "books": ["000387a0-7784-4cf7-9672-2e8cadc725cd"]
}
```
**Response**: `204 No Content`

### Remove Books from Collection
`DELETE /api/v2/collections/books`

**Request Body:**
```json
{
  "collections": ["da940d66-3580-4111-9ac2-d8ab8578fbae"],
  "books": ["000387a0-7784-4cf7-9672-2e8cadc725cd"]
}
```
**Response**: `204 No Content`

---

## 4. Playback and Media

### Stream Audiobook
`GET /api/v2/books/{uuid}/files?format=audiobook`

**Headers:**
```http
Range: bytes=0-1024
```

**Response Headers:**
```http
Content-Type: audio/mp4
Accept-Ranges: bytes
Content-Length: 1025
```

### Fetch Book Cover

**Headers:**
```http
Range: bytes=0-1024
```

**Response Headers:**
```http
Content-Type: audio/mp4
Accept-Ranges: bytes
Content-Length: 1025
```

`GET /api/v2/books/{uuid}/cover?w={width}&h={height}`

---

## 5. Book Operations & Lifecycle

### Update Book Status
`PUT /api/v2/books/{uuid}/status`
**Request Body**: `{"status": "STATUS_UUID"}`

### Fetch Available Statuses
`GET /api/v2/statuses`
Returns the status UUIDs used for the `PUT /status` endpoint.

**Response Example:**
```json
[
  { "uuid": "6ab3dd21-fc4a-4650-a4d4-beaad22fdd45", "name": "To read" },
  { "uuid": "2ef7545b-7d9a-4f3c-9c4b-4da6adf79f2e", "name": "Reading" },
  { "uuid": "602f0f9a-fb2a-4edf-aeb8-c598ff35e5ff", "name": "Read" }
]
```

### Manual Metadata Match
`GET /api/v2/books/{uuid}/match?query={search_term}`
Scrapes external providers for metadata candidates.

### Batch Processing
`POST /api/v2/books/_/process`
Trigger background tasks for multiple books.

**Request Body:**
```json
{
  "books": ["UUID_1", "UUID_2"],
  "type": "REFRESH_METADATA" 
}
```
**Response**: `204 No Content`

### Update Metadata
`PUT /api/v2/books/{uuid}`

### Delete Book
`DELETE /api/v2/books/{uuid}`

---

## 6. Progress & Navigation

> [!NOTE]
> **Alignment Prerequisite**: Detailed progress tracking and chapter navigation require the book to be "aligned" (audio-to-text sync) using the server's processing engine.

### Sync Position (Absolute)
`POST /api/v2/books/{uuid}/progress`
Updates the user's current reading/listening position.

**Request Body:**
```json
{
  "position": 123.45,
  "unit": "seconds"
}
```

### Fetch Navigation (Chapters)
`GET /api/v2/books/{uuid}/navigation`
Returns chapter markers and navigation structure for an aligned book.

**Response Example:**
```json
[
  {
    "title": "Chapter 1",
    "start": 0,
    "end": 300
  },
  {
    "title": "Chapter 2",
    "start": 300,
    "end": 650
  }
]
```

---

## 7. User Administration

### Fetch Current User
`GET /api/v2/user`

**Response Example:**
```json
{
  "id": "b2633443-a900-48b4-b281-aff24e0df61c",
  "name": "Reader",
  "username": "reader",
  "email": "reader@example.invalid",
  "permissions": {
    "bookRead": 1,
    "bookDownload": 1,
    "settingsUpdate": 1
  }
}
```

### Update User Permissions
`PUT /api/v2/users/{uuid}`

**Request Body:**
```json
{
  "permissions": {
    "bookCreate": true,
    "bookRead": true,
    "bookProcess": true,
    "bookDownload": true,
    "bookList": true,
    "bookDelete": true,
    "bookUpdate": true,
    "collectionCreate": true,
    "inviteList": true,
    "inviteDelete": true,
    "userCreate": true,
    "userList": true,
    "userRead": true,
    "userDelete": true,
    "userUpdate": true,
    "settingsUpdate": true
  }
}
```
**Response**: `204 No Content`

### Create Invitation
`POST /api/v2/invites`

**Request Body:**
```json
{
  "email": "testuser@example.com"
}
```

**Response Example:**
```json
{
  "id": "e5f49eb62085",
  "email": "testuser@example.com",
  "expiresAt": "2026-04-08 23:07:00"
}
```

---

## 8. Server Configuration

### Fetch All Settings
`GET /api/v2/settings`

**Response Example (Subset):**
```json
{
  "libraryName": "Research Library",
  "smtpHost": "smtp.example.com",
  "smtpPort": 587,
  "smtpSsl": true,
  "transcriptionEngine": "whisper.cpp",
  "whisperModel": "tiny"
}
```

### Update Settings
`PUT /api/v2/settings`

---

## 9. System & Real-time Events

### Real-time Events (SSE)
`GET /api/v2/books/events`

**Stream Example:**
```http
event: bookUpdate
data: {"uuid": "000387a0-7784-4cf7-9672-2e8cadc725cd", "status": "Reading"}
```

### Filesystem Browser
`GET /api/v2/filesystem?path={urlEncodedPath}`

**Response Example:**
```json
[
  {
    "name": "Fiction",
    "isDirectory": true
  },
  {
    "name": "metadata.json",
    "isDirectory": false,
    "size": 1024
  }
]
```

### Max Upload Chunk Size
`GET /api/v2/settings/maxUploadChunkSize`

**Response Example:**
```json
{
  "size": 5242880
}
```
