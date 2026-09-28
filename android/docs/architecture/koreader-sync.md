# KOReader / KOSync interoperability

Enve talks the KOSync protocol from two places:

- `engine/data/sync/KOReaderHubClient` + `KOReaderHubService` — the standalone **KOReader Hub**, configured in Settings and backed by `KOReaderHubConfig`. It syncs ebook progress against any KOSync-compatible server.
- `engine/data/sync/KosyncClient` + `BookloreKoreaderSink` — the KOSync endpoint a Booklore/Grimmory connection exposes under `/api/koreader`.

Neither is a `ProviderAdapter`. KOSync is a progress transport, not a library backend.

## Transport rules

- **Any 2xx is success.** The reference kosync server answers `200`; Spring-based implementations (Booklore/Grimmory) answer `201`/`204`. Treating only `200`/`201`/`202` as success made every push against those servers fail after a successful pull.
- **`204` and an empty 2xx body mean "no remote progress"**, not an error. They take the same path as `404`.
- The reference server answers a missing record with `200 {}`; a record whose `progress` is blank and whose `percentage` is `0` is also treated as absent. Both clients apply the same rule.
- Servers that omit `document` in the response still produce a usable record — the requested hash is filled in.
- Credentials travel as `x-auth-user` / `x-auth-key` headers. `x-auth-key` is the MD5 of the password; the plaintext password is never stored or sent.
- Pushes carry only `document`, `progress`, `percentage`, `device` and `device_id`. Enve does not send book metadata — no title, author or file name leaves the device beyond the opaque document ID.

## Document matching

KOSync identifies a book by an opaque 32-character document ID. Clients disagree on how they derive it:

| Client | Default | Derivation |
|---|---|---|
| KOReader | binary | partial MD5 of the file (`PartialMd5`, 1 KiB at offsets `0`, `1024 << 2i`) |
| CrossPoint Reader | filename | MD5 of the bare file name |

`KOReaderBookLink` can hold both identities:

- `documentHash` — the binary ID. Computed automatically from the downloaded file, or pinned by hand. Blank when the book has only a file-name identity.
- `filename` — the CrossPoint file name. **Only ever set explicitly**, in the KOReader Hub's link editor. `KOReaderDocumentId.filenameSuggestion` derives a *suggestion* from `book.id` to prefill that field, but nothing is inferred for sync: a link with no stored `filename` behaves exactly as it did before CrossPoint support existed.

`KOReaderHubService.documentIdsFor` resolves the two:

- **Push** writes to a single ID — the file-name ID when one is configured, otherwise the binary hash. Fanning out to both would raise two connector events per page turn on servers that broadcast writes.
- **Pull** queries every configured ID (push target first) and keeps the record with the newest usable `timestamp`; with no usable timestamps, or on a tie, it keeps the first candidate (`selectRemoteRecord`).

Adding a file name never rewrites `documentHash`, and a changed binary hash carries the file name forward (`repairedLink`), so enabling CrossPoint matching cannot break an existing link. A file-name-only link keeps `documentHash` blank, so the editor never shows a file-name MD5 in the hash field and saving it cannot turn one into a manual binary pin; once the ebook file is available locally, `ensureDocumentHash` still computes the real partial MD5 for that link.

## Position payloads

`KOReaderHubXPointerConverter` maps between KOReader XPointers and Readium locators.

- XPointer shape: `/body/DocFragment[N]/body/div[2]/section[1]/p[4]/text()[2].12`. The text tail is optional and its index is optional (`/text().12`), as is a bare element offset (`p[4].0`).
- Element steps resolve by **walking the ancestry from `<body>`**, picking the *i*-th child with that local name at each level. Resolving the last segment globally silently picked the wrong node in any document with repeated tags.
- CFI steps come from the parsed DOM: an element is `2 * (element sibling index + 1)`, counted from the content document's root element, so the leading step is whatever `<body>` actually is rather than a hard-coded `/4`.
- Odd CFI steps are **character-data chunks, not text nodes**. A chunk is every text node and CDATA section between two element siblings, so its step is `2 * (element siblings before it) + 1` and its offset spans the concatenated nodes. Comments and processing instructions are skipped: they neither split a chunk nor shift an element index. A KOReader `text()[2]` inside `<p>before<!--c-->after</p>` is therefore offset `6` of chunk `1`, not chunk `3`.
- KOReader offsets are Unicode code points (crengine stores `lChar32`); CFI offsets are UTF-16 code units. The converter translates in both directions and snaps a CFI offset that lands inside a surrogate pair back to the start of that code point.
- Offsets past the end of the addressed text clamp to its last position.
- Reverse conversion **fails rather than guessing**: range CFIs (`a,b,c`), a character-data step that is not final, a step that does not resolve to an existing node, a character offset on an element step, and a path not rooted at `<body>` all return `null` instead of a truncated, plausible-looking xpointer.
- Reverse conversion accepts the flattened Readium key `locations.partialCfi`, and otherwise whatever `EpubBridgeCheckpointCodec.cfi` finds (`locations.fragments[0]`, `locations.cfi`, or an `EpubBridgeCheckpoint`'s `epubCfi`), dropping everything before `!`.

Emitted locators follow Readium's Kotlin `Locator` JSON: `Locator.Locations.otherLocations` is **flattened into `locations`**, so the extras are written as `locations.partialCfi` and `locations.cfi` (`locations.otherLocations.partialCfi` would come back as `locations["otherLocations"]` and be unreadable). `locations.cfi` is the app-canonical full CFI, `epubcfi(/6/<2*(spine+1)>!<partial>)`, matching `ReaderViewModel.readiumSelectionCfi` and `AnnotationRepository`.

Spine and spine-item parsing use jsoup's XML parser and match on local names, so namespace-prefixed OPF and XHTML work and the converter is covered by plain JVM unit tests. Note that the mapping is faithful to the parsed DOM, which keeps whitespace-only text nodes that crengine may drop; `text()[n]` indices therefore agree with KOReader for text inside leaf elements, which is where KOReader puts them.

## Server presets

The KOReader Hub screen offers two well-known endpoints — CrossPoint (`https://sync.crosspointreader.com`) and KOReader (`https://sync.koreader.rocks:443`). The preset list is UI copy and lives with the screen in `:app`; the buttons only prefill the server URL field, and there is no CrossPoint-specific persistence.
