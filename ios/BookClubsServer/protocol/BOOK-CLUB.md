# Book Club Protocol 1.0 draft

Book Club is a JSON-over-HTTP protocol for people reading together. This draft describes the interface independently of the Enve apps and of any particular storage engine. The [OpenAPI document](openapi.json) describes request and response types.

## Instance and identity

1. `GET /v1/discovery` returns `protocol: "book-club"`, its version, API base, and available features. Start with the instance address chosen by the member. Public deployments should use HTTPS.
2. `POST /v1/accounts` creates an account from a display name. Store the returned session token securely and give the recovery key to the member. A recovery key can start another session with `POST /v1/sessions`. Include `Authorization: Bearer <token>` on authenticated requests, and revoke a session on sign-out.
3. IDs are opaque and scoped to an instance. An invite code belongs to the instance that issued it. The browser uses `https://<instance>/#join=<code>` so the fragment stays out of the initial HTTP request. Use `POST /v1/clubs/join` with the code. The optional `name` sets the name visible in that club.
4. Each club belongs to one instance. Independently hosted instances have separate accounts, clubs, and invites. Compatible apps can talk to any instance by using its API.

Successful JSON mutations return a result such as `{"id":"…"}` or `{"ok":true}`. Failed requests return a non-2xx status and `{"error":"…"}`. HTTP 401 means the session is missing or expired, 403 means the member lacks the required role, and 404 can mean the resource is out of scope for that account. Treat cursors as opaque and keep other query parameters unchanged when following them. Clients should tolerate additional response fields. Timestamps are Unix milliseconds and reading fractions range from 0 to 1.

## Reading, sharing, and notes

- `GET /v1/clubs` lists active memberships. The current reading fields `currentTitle`, `currentReadID`, and `currentAuthor` can populate a client shelf. The optional `nextCheckpoint` contains the requesting member’s first unfinished checkpoint in plan order, with `label` and nullable `dueAt`. It is null when the member has no unfinished checkpoint. Clients should tolerate instances that omit these added fields. The host starts a read using title and author metadata and may add ordered checkpoints. Starting a new read archives the previous one. Members can use their own copy or download the copy shared by the host.
- Manual check-ins advance the member through a checkpoint and earlier checkpoints in that read. Every member can see club check-ins. Automatic progress and reading presence require explicit per-read choices. Send the latest sharing epoch with a progress update. The server ignores older observations and expires temporary presence.
- General and chapter discussions are scoped to the club. Clients should gate a chapter thread behind a check-in or member-confirmed spoiler reveal. Replies, reactions, blocking, and reports use IDs returned by the service.
- A note is private by default. Explicit `visibility: "club"` shares it with members of that club. Shared notes attached to checkpoints appear after a check-in or explicit `revealSpoilers=true`. An author can update a note's text, checkpoint, or visibility. A host cannot use the API to read private notes or edit another member's notes.
- An author's notes remain available through `GET /v1/me/notes` after leaving a club. When a read is deleted, attached notes become private, preserve the book title, and lose their club/read link. The author can still delete them. Account deletion removes the account's notes.
- Names, nominations, votes, and activity are displayed within the club. A club nickname changes display attribution while the member ID remains the same.

## Discussion and activity

Instances advertising `discussion-prompts` return a nullable `prompt` with `body` and `updatedAt` on general and checkpoint thread responses. On an active read, the host can pin or replace it with `PUT /v1/clubs/{club}/reads/{read}/threads/{thread}/prompt` and a `body` of up to 1,000 characters. DELETE on the same path removes it.

Instances advertising `post-spoilers` accept a boolean `isSpoiler` on posts. Replies to marked posts inherit the flag. A thread response sets `concealed` for other viewers and returns an empty body and null passage fields. Fetch `GET /v1/clubs/{club}/reads/{read}/posts/{post}` after a viewer chooses to reveal that post. The service checks current membership and blocks. Clients should continue to gate the whole checkpoint thread as well.

Instances advertising `club-feed` serve `GET /v1/me/feed`. The response contains up to 40 newest-first events and a nullable `before` cursor. Events can identify the club, member, action, and reading title. Post bodies, quoted passages, and reading notes stay out of the feed. Membership and blocks apply on each page request. Post events may include a `discussion` link with `clubID`, `readID`, `threadID`, and `postID`. Open that reading’s thread, including archived readings, and apply the existing checkpoint gate before loading it. Use `?focus=<postID>` on the thread request to get a separate `focusedPost` even if it falls outside the current page. A focused spoiler is still concealed. The field is null if the post was removed, blocked, or belongs to a different thread.

## Catalog adapter contract

Catalog plugins map provider metadata to Book Club's publication format. `GET /v1/clubs/{club}/catalog` describes available sources. Each source returns publication metadata, optional navigation links represented by opaque cursors, and a next-page cursor. The built-in service asks its provider for metadata on demand.

An independent HTTP adapter can expose a GET endpoint accepting optional `q` for search and `cursor` for continuation. Return JSON like:

```json
{
  "publications": [
    {
      "id": "local-123",
      "title": "Persuasion",
      "author": "Jane Austen",
      "series": null,
      "format": "ebook"
    }
  ],
  "nextCursor": null
}
```

Use stable item IDs and the format values `ebook`, `audiobook`, or `unknown`. The reference server converts provider IDs and cursors to opaque public values. Use at most 100 publications per page and continue using `nextCursor` when needed. Provider URLs, files, authentication tokens, and private library identifiers are outside the publication format. Only the instance operator configures an adapter and its upstream credentials.

## Reference behavior

The SQLite reference service ships the browser client and catalog adapters. The Cloudflare Worker runs the same club protocol and storage migrations. The conformance tests exercise new accounts joining over HTTP, chapter check-ins, discussions, club-specific names, progress sharing, notes, voting, and the catalog adapter contract.

## Hosted copies

An instance advertising "hosted-copies" accepts POST /v1/clubs/{club}/reads/{read}/copy from the host of a current reading. Submit the catalog source ID, its current opaque publication ID, and a format from the publication's shareableFormats list. A response of 202 starts a background import. GET on the same route returns the published copy manifest, whether an import is underway, and any import error visible to the host. DELETE revokes the copy and cancels an import. A failed import preserves the earlier manifest and files.

The read response also includes the published manifest as hostedCopy. Use its ID and the zero-based file indexes to fetch /v1/clubs/{club}/reads/{read}/copy/{copy}/files/{index}. Send the existing bearer session in the Authorization header for GET or HEAD. Single byte ranges are supported. Each file supplies its name, size and media type. Clients downloading a multipart audiobook should group files in manifest order. The server authorizes each file request against current membership and the current manifest. Provider addresses and credentials stay on the host server.
