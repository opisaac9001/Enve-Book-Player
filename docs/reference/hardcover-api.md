# Enve: Hardcover.app Integration Master Guide

This guide covers authentication, metadata discovery, and progress synchronization through the Hardcover GraphQL API.

---

## 1. Core Architecture

Hardcover integration is built on three pillars:

1.  **`HardcoverService` (API Client)**: A stateless client for GraphQL queries and mutations. Handles snake_case decoding and raw network calls.
2.  **`HardcoverSyncService` (Sync Manager)**: An `actor` that persists the state of matches, resolves edition details (like page counts), and throttles API calls during playback.
3.  **`SettingsManager` (Persistence)**: Stores the Bearer token and `HardcoverBookMatch` records.

---

## 2. Authentication

Hardcover uses a Bearer token (JWT) for all requests. 

*   **Endpoint:** `https://api.hardcover.app/v1/graphql`
*   **Method:** `POST`
*   **Header:** `Authorization: Bearer <TOKEN>`

> [!CAUTION]
> **Token Expiration**: If a query returns a `JWTExpired` error in the GraphQL response, the app should clear the `hardcoverApiKey` and prompt the user to re-authenticate.

---

## 3. The Matching Engine

To sync a local book, Enve must find its Hardcover `book_id`. 

### A. Discovery (Search)
Use the `search()` endpoint for high-performance discovery. This is powered by Typesense.

**Query:**
```graphql
query SearchBooks($query: String!) {
  search(query: $query, query_type: "Book", per_page: 10, page: 1) {
    results
  }
}
```

### B. Similarity Scoring
When searching, Enve uses a multi-step matching algorithm found in `HardcoverSyncService.swift`:
1.  **Title Normalization**: Lowercase, strip punctuation/whitespace.
2.  **Author Exact Match**: Check if the Hardcover `author_names` array contains the local author.
3.  **Levenshtein Distance**: A fuzzy matching check (threshold: 0.85 similarity) used if exact title matching fails.

---

## 4. Deep Metadata (Series & Characters)

For a "deep integration," use the `books_by_pk` entry to fetch enriched metadata.

**Query:**
```graphql
query BookEnrichment($id: Int!) {
  books_by_pk(id: $id) {
    title
    book_series {
      series { name }
      position
    }
    book_characters {
      character { name id }
    }
  }
}
```

---

## 5. Progress Synchronization Logic

Hardcover only understands **Page Progress**. Enve must convert all media types into "Pages."

### Audiobook Sync (Seconds -> Pages)
1.  Find the **Edition ID** (the specific audiobook version).
2.  Fetch `edition_format` and `pages` (or `duration_seconds` if available).
3.  Formula: `(Current Second / Total Seconds) * Edition Page Count = Current Page`.

### Ebook Sync (Percentage -> Pages)
1.  Resolve the book's total `pages` from Hardcover.
2.  Formula: `Current Percentage * Total Pages = Current Page`.

**Movement Mutation:**
```graphql
mutation SyncProgress($readId: Int!, $page: Int!) {
  update_user_book_read(id: $readId, object: { progress_pages: $page }) {
    user_book_read { id progress }
  }
}
```

---

## 6. Social Features (The Hub)

### Trending Books
**Query:**
```graphql
query Trending {
  books(limit: 20, order_by: {users_count: desc}) {
    id title image { url }
  }
}
```

### Friend Activity Feed
**Query:**
```graphql
query FriendFeed {
  me {
    following {
      following {
        username
        user_books(limit: 5, order_by: {updated_at: desc}) {
          status_id
          book { title }
        }
      }
    }
  }
}
```

---

## 7. Development Best Practices

1.  **JSON Strategy**: Use `JSONDecoder().keyDecodingStrategy = .convertFromSnakeCase`.
2.  **ID Mapping**: In search results, IDs are `Strings`. In the main GraphQL schema, they are `Ints`. Convert strings to ints before library operations.
3.  **Rate Limiting**: Hardcover limits are 60 req/min. Use the `syncedBookStarts` cache in `HardcoverSyncService` to prevent redundant "Start Session" calls.
