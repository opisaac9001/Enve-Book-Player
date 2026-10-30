# Book-position sharing

One person shares a QR code for a book's current position. The recipient scans it inside Enve, selects a compatible copy from their own libraries, and confirms before its saved position changes. Audio uses an absolute timestamp; ebooks bundle CFI, a portable Readium locator, reading progress, and a chapter offset when available; PDFs and comics preserve a page when known. Codes contain book metadata and position only, never an account, token, server address, library identifier, or access grant.

This document is the cross-platform contract. The Android implementation is `ListeningPositionPayload` in `:core`, with JVM interoperability tests using the fixtures below. Both platforms must produce byte-identical encodings for the encoding fixtures and the same accept/reject decisions for the decoding fixtures.

## Reading payload, version 2

Ebooks, PDFs, comics, and other supported text formats use `v:2` with the same `k`, `t`, and optional metadata fields as audio. They omit `pos` and `dur`; decoders reject mixed audio/reading fields.

| Key | Type | Required | Rule |
|---|---|---|---|
| `m` | string | yes | Exactly `reading` |
| `f` | string | yes | Lowercase format, 1–16 ASCII letters/digits; `comic` groups CBZ/CBR/image folders, `pdf` identifies PDF |
| `p` | integer | yes | Whole-book progression in millionths, from 0 to 1,000,000 |
| `h` | string | no | Relative chapter resource, at most 256 Unicode scalars; no scheme, absolute path, query, fragment, controls, or decoded parent-path segment |
| `o` | integer | with `h` | Resource progression in millionths, from 0 to 1,000,000; `h` and `o` occur together and are rejected for PDF/comic formats |
| `c` | string | no | Full EPUB CFI, at most 2048 UTF-8 bytes; not used for PDF/comic formats |
| `l` | string | no | Sanitized compact Readium locator JSON; not used for PDF/comic formats |
| `page` | integer | no | One-based PDF/comic page, from 1 to 1,000,000; other formats reject this field |
| `pages` | integer | no | Sender's known page count; requires `page` and must be at least that page, at most 1,000,000 |

The compact UTF-8 encoding is limited to 2200 bytes, with keys sorted in ascending byte order and the same string escaping as audio. A minimal canonical fixture is:

```json
{"f":"epub","k":"enve.position","m":"reading","p":250000,"t":"A Book","v":2}
```

`c` and `l` are optional additions to version 2. Older codes remain valid. Older apps may ignore the new fields or reject codes larger than their former 1024-byte limit.

The locator in `l` keeps only `href`, `type`, `locations`, and `text`. Its relative `href` follows the `h` rules; `type` is `application/xhtml+xml` or `text/html`. Locations may contain `progression`, `totalProgression`, `position`, `fragments`, `cfi`, `partialCfi`, `cssSelector`, `domRange`, and `enveSourceEngine`. Text may contain `before`, `highlight`, and `after`, preserving whitespace. Unknown fields are removed; malformed known fields reject the code. DOM points contain a selector, a non-negative text-node index, and an optional non-negative character offset. Numeric indices are bounded to one billion, fractions to 0–1, anchor strings to 2048 UTF-8 bytes, and fragments to 32 entries of at most 512 Unicode scalars. Engine names are limited to `readium` and `foliate`.

Locator objects are recursively key-sorted, with numbers emitted in plain decimal form without trailing fractional zeroes and JSON string escaping retained. Native checkpoint data is converted into this locator; publication fingerprints, provider file IDs, revision counters, account data, and local state are never exported. All available location representations travel together. Metadata may be shortened to fit the QR budget, but position anchors are never removed to make a code fit; a position that exceeds the budget cannot be shared as one QR code.

For the same format, the recipient restores the portable locator together with the CFI and retains percentage as fallback. Different formats use percentage, while matching PDFs/comics retain their page. The existing reader resolves the best anchor supported by the recipient's copy.

A page can be shared without a count. When a compatible recipient copy has a known count, an out-of-range page is rejected; otherwise its exact native page locator is retained for reader opening. Reading percentages are a fallback across different formats or editions and may land on a different passage. Chapter resource paths are accepted only as internal relative resources; codes never open URLs or grant book access. No selected book starts reading or playing automatically.

Matching filters audio codes to audio entries and reading codes to reading entries. Reading matches use title/author and edition identifiers, without audio-duration/narrator penalties. Format or page-count differences produce warnings, and selection plus confirmation is always required.

Acceptance replaces the selected copy's saved progress and stale locator, including explicit backward/zero moves and finished-state reset. Provider updates use the existing profile-specific ebook/audio queues. Queued reading positions take priority over stale remote restore data; explicit shared PDF/comic page locators also retain their page after acknowledgement or when server sync is off. The local `enveSharedPosition` marker is never transmitted in the QR payload.

## Audio payload, version 1

The QR code's message is a single UTF-8 JSON object. Error correction level M is recommended.

| Key | Type | Required | Rule |
|---|---|---|---|
| `k` | string | yes | Exactly `enve.position` |
| `v` | integer | yes | Format version. `1` for audio |
| `pos` | integer | yes | Absolute playback position in milliseconds, `0 ≤ pos ≤ dur` |
| `dur` | integer | yes | Sender's total duration in milliseconds, `0 < dur ≤ 3600000000` (1000 hours) |
| `t` | string | yes | Title, 1–160 Unicode scalars |
| `a` | array of strings | no | Authors, at most 4, each 1–100 scalars |
| `n` | array of strings | no | Narrators, at most 4, each 1–100 scalars |
| `s` | string | no | Series name, 1–120 scalars |
| `q` | string | no | Position within the series as the sender's library spells it (`"1"`, `"2.5"`), 1–16 scalars |
| `asin` | string | no | 10 characters, `A–Z` and `0–9` only |
| `isbn` | string | no | ISBN-10 (`[0-9]{9}[0-9X]`) or ISBN-13 starting `978`/`979`, no separators |

Every metadata string field is **text-canonical**: Unicode NFC; no characters of general category `Cc` or `Cf` other than U+200C and U+200D; no U+2028 or U+2029; no leading or trailing whitespace; no run of more than one whitespace character, and the only whitespace character is U+0020.

### Canonical encoding

Encoders emit exactly one form:

1. Keys in ascending byte order: `a`, `asin`, `dur`, `isbn`, `k`, `n`, `pos`, `q`, `s`, `t`, `v`.
2. Absent optional fields are omitted. Empty arrays are omitted.
3. No whitespace outside strings. Separators are `,` and `:`.
4. Integers in plain decimal, no sign for non-negative values, no exponent, no fraction.
5. Strings escape only `"` as `\"` and `\` as `\\`. Every other character, including non-ASCII, is written as raw UTF-8. Text-canonical metadata never contains characters that JSON requires to be escaped. The nested locator string uses JSON escaping for its preserved text whitespace and control characters.
6. The whole encoding is at most **2200 bytes**.

To build a code from library metadata, the sender:

- normalizes each string to text-canonical form and truncates it to its scalar limit on a character (grapheme) boundary;
- splits a narrator string on `,`, `;` and `&`; removes case-insensitive duplicate names; keeps the first four;
- uppercases an ASIN and strips `-` and spaces from an ISBN, omitting either if still invalid;
- includes `q` only alongside `s`;
- floors `pos` and `dur` to whole milliseconds and clamps `pos` into `[0, dur]`;
- refuses to make a code without a positive finite duration, or for a reading copy; audiobooks and podcast episodes use this shape;
- if the result exceeds 2200 bytes, drops `n`, then `s` and `q`, then all authors but the first, re-checking after each step.

### Decoding

Decoders must:

- reject input over 2200 bytes before parsing it;
- reject anything that is not a JSON object whose `k` is `enve.position` (including URLs and arbitrary text) as *not a listening position*;
- reject a missing, non-integer, boolean or `< 1` `v` as invalid, and any `v` greater than the supported version as *unsupported version* so the user can be told to update;
- reject `pos`/`dur` that are missing, strings, booleans, fractional, non-finite, negative, or outside the ranges above;
- reject any present field that has the wrong JSON type, exceeds its limits, or is not text-canonical;
- ignore unknown keys. A new optional key does not change the version; a change that alters the meaning of an existing key does.

A decoder never opens, fetches, or resolves anything named in a code. Unknown keys are discarded unread.

### Fixtures

Encoding fixtures. Decoding each must succeed, and re-encoding the decoded value must reproduce the bytes exactly.

```json
{"a":["Brandon Sanderson"],"asin":"B003ZWFO7E","dur":163980000,"k":"enve.position","n":["Michael Kramer","Kate Reading"],"pos":3723500,"q":"1","s":"The Stormlight Archive","t":"The Way of Kings","v":1}
```

```json
{"dur":3600000,"k":"enve.position","pos":0,"t":"Untitled Recording","v":1}
```

```json
{"a":["Antoine de Saint-Exupéry"],"dur":5400000,"isbn":"9782070612758","k":"enve.position","pos":1,"t":"Le \"Petit\" Prince \\ Édition","v":1}
```

Accepted with the unknown key discarded; re-encodes without `url`:

```json
{"dur":3600000,"k":"enve.position","pos":10,"t":"Book","url":"http://192.168.1.2/api","v":1}
```

Rejected:

| Input | Result |
|---|---|
| `{"dur":3600000,"k":"enve.position","pos":0,"t":"X","v":3}` | unsupported version 3 |
| `{"dur":3600000,"k":"enve.position","pos":0,"t":"X","v":0}` | invalid `v` |
| `{"dur":3600000,"k":"enve.position","pos":0,"t":"X","v":true}` | invalid `v` |
| `{"dur":3600000,"k":"enve.position","pos":0,"t":"X"}` | invalid `v` |
| `{"dur":3600000,"k":"enve.position","pos":-1,"t":"X","v":1}` | invalid `pos` |
| `{"dur":3600000,"k":"enve.position","pos":3600001,"t":"X","v":1}` | invalid `pos` |
| `{"dur":3600000,"k":"enve.position","pos":1.5,"t":"X","v":1}` | invalid `pos` |
| `{"dur":3600000,"k":"enve.position","pos":"10","t":"X","v":1}` | invalid `pos` |
| `{"dur":3600000,"k":"enve.position","pos":1e400,"t":"X","v":1}` | rejected (non-finite) |
| `{"dur":0,"k":"enve.position","pos":0,"t":"X","v":1}` | invalid `dur` |
| `{"dur":3600000001,"k":"enve.position","pos":0,"t":"X","v":1}` | invalid `dur` |
| `{"dur":3600000,"k":"enve.position","pos":0,"t":"","v":1}` | invalid `t` |
| `{"dur":3600000,"k":"enve.position","pos":0,"t":"A\nB","v":1}` | invalid `t` (not text-canonical) |
| `{"a":["1","2","3","4","5"],"dur":3600000,"k":"enve.position","pos":0,"t":"X","v":1}` | invalid `a` |
| `{"a":"Single","dur":3600000,"k":"enve.position","pos":0,"t":"X","v":1}` | invalid `a` |
| `{"asin":"b003zwfo7e","dur":3600000,"k":"enve.position","pos":0,"t":"X","v":1}` | invalid `asin` |
| `{"dur":3600000,"isbn":"12345","k":"enve.position","pos":0,"t":"X","v":1}` | invalid `isbn` |
| `{"dur":3600000,"k":"other.app","pos":0,"t":"X","v":1}` | not a listening position |
| `https://example.com/position?t=10` | not a listening position |
| `[1,2,3]` | not a listening position |
| Any valid code followed by enough padding to exceed 2200 bytes | too large |

## Sending

The book details' More menu offers **Share book location** for supported reading entries and audio with a known duration. The sheet captures the latest saved reading position or the live position of a loaded audio book. **Update position** recaptures it. **Share image** exports the code as an image so it can be sent and later imported by the recipient.

## Receiving

Library ▸ More ▸ **Scan book position** opens the scanner. It uses the live camera (VisionKit) when the device supports it and camera access is granted, and always offers **Choose an image**, which reads QR codes from a photo or screenshot on-device. Image import is the path on the Simulator and when camera access is denied. Imports use a temporary file, reject files above 20 MiB before reading their data, inspect dimensions without caching the full image, and reject dimensions above 16,384 pixels or 100 million total pixels. The first frame is downsampled with orientation applied to a maximum dimension of 2,048 pixels before QR detection. Temporary files are removed after import. These bounds reduce memory exposure; they do not establish trust in a code or eliminate image-framework vulnerabilities. A rejected code is reported once and scanning continues.

### Matching

Candidates are compatible audio or reading copies from the recipient's connected sources. Copies of the same book on different accounts or servers are separate candidates.

- **Identity** comes first: a matching ASIN or ISBN, or a title similarity ≥ 0.85 together with an author similarity ≥ 0.8 (or no author on one side). Title and author scoring reuses `MatchingUtils` and `CanonicalBookIdentity` normalization from the metadata matcher; titles are compared in both directions so a subtitle on either side is dropped.
- **Recording** signals then order credible copies: duration within two minutes, matching narrator, and series position.
- Automatic suggestions list credible copies only. **Search your library** returns every compatible book matching the query, credible or not, so the recipient can choose a copy that suggestions omitted.
- The score orders results; it is not a calibrated probability and is never displayed as one. Rows show the reason instead (same title and author, same length, or the first warning).

Warnings shown before confirming: title differs, author differs, length differs by N minutes, length unknown, different narrator, different book in the series, and shared time past the end of this copy. The last one blocks applying. The position is always applied as the same absolute timestamp; Enve does not rescale it between recordings.

### Applying

Applying always requires an explicit confirmation that shows the copy's current and new positions. It never starts playback. `ListeningPositionApplier` runs each acceptance on a `PerBookSerialQueue` keyed by the copy's stable ID, so two acceptances for the same copy cannot interleave:

1. If that copy is loaded in the player (playing or paused), seek it first, so the player's periodic saves already carry the new position. A paused player stays paused.
2. Write the position locally through `UserProgressStore.update`, `BookProgressStore`, and `LinkedBookProgressCoordinator`, stamped with the acceptance time.
3. If server sync is enabled and the copy has a provider sync sink, write a durable `PendingSyncQueueStore` entry first. It replaces any older queued update for this copy and survives termination.
4. Push immediately through `SyncCoordinator.pushAudiobookProgress(forceImmediate:)`, which also cancels a debounced push still carrying the old position.
5. Report the server state from the durable queue: entry removed means the server accepted it; entry present means it is queued for retry; a suspended entry with a validation message means the server rejected it. Enve never reports a server save before the provider has accepted it. Copies with no server, or with server sync off, report that only this device changed.

## Android workflow

The book details three-dot menu offers **Share book location** for supported reading entries and audio with a known duration. The sheet captures a snapshot when opened. **Update position** captures another snapshot; **Share image** exports only the QR bitmap through a narrowly scoped FileProvider cache directory.

Library's More menu opens **Scan book position**. Live scanning requests camera permission when the user enables it. Camera and autofocus hardware are explicitly optional, so the new permission does not filter out camera-less readers or devices with only a front camera. Image import accepts a selected `content:` URI, streams at most 20 MiB to a private temporary file, checks dimensions before decoding, and downsamples to at most 2,048 pixels per dimension. Images above 16,384 pixels in either dimension or 100 million total pixels are rejected. Temporary imports are removed on completion or cancellation. The camera closes when the view leaves composition or the activity pauses. Camera frames and imported images are processed on-device.

`ListeningPositionMatcher` reuses the metadata matcher's title, author and duration scoring. Identity requires a matching ISBN or a title score of at least 0.85 with an author score of at least 0.8 when both authors are known. Duration, narrator and series position order candidates and produce recording warnings. Account/source labels distinguish copies. Scores are ordering weights, never confidence percentages. Manual search keeps results outside the suggestion threshold. A time beyond the selected copy's known end cannot be applied.

The UI calls `ListeningPositionFacade` through the profile's ViewModel factory. `ListeningPositionApplier` reloads the selected copy, serializes per-copy acceptance, seeks it only if already loaded, then writes its progress and pending server update in a transaction. The existing writer coordinator, checkpoint ordering, connection-aware repository and pending-write acknowledgement remain responsible for synchronization. A finished copy can move backwards into re-reading. Nothing starts playback. A missing pending entry after the provider call is required before reporting server acceptance; an unconfirmed write remains queued. Disabled server sync and copies without a progress server report local-only success. When a recipient copy's duration is unknown, only the local absolute time is saved; refresh its details and accept the code again before sending a server percentage.

The wire payload uses milliseconds. Android's existing book cache and provider progress pipeline persist positions with whole-second precision. No proportional rescaling is performed between recordings. A code is unsigned public metadata; matching is not proof of authenticity, and selecting and confirming a local copy is always required.

## Verification

- JVM tests cover the iOS canonical fixtures byte for byte, malformed types, Unicode/control characters, unknown fields, oversized and randomized payloads, ranking across recordings/accounts, out-of-range times and serialized acceptance.
- Emulator integration tests use an isolated profile to verify local rewinds, finished-state reset, copy isolation and local-only behavior with unknown duration.
- QR tests import an actual iOS screen capture, round-trip a Unicode Android QR through the file importer, reject malformed/oversized images and non-content URI sources, and exercise malformed Unicode/nested JSON on Android.
- Compose tests cover explicit confirmation, manual search outside suggestions, light/dark presentation, large text and camera release. The emulator camera test also waits for actual preview image data before closing it.
- The Android-generated Unicode QR was imported through the iOS photo picker into its matching screen on iPhone Air Simulator.

A physical iOS/Android camera exchange, loaded-player behavior on hardware, and progress acknowledgement against each supported live provider remain release checks. Simulator/emulator tests do not establish those provider or optical-scanning results.

The Android dependency is ZXing **Core** 3.5.4, not the discontinued Barcode Scanner app or its intent integration. The Android 14 warning in the [upstream README](https://github.com/zxing/zxing#readme) refers to that standalone app. Current instrumentation runs used Android 16 (API 36); Android 14 itself was not separately exercised.

Verified October 28, 2026: debug and minified release builds passed with no new compiler warnings. The affected module unit suites reported 1,299 tests, zero failures and one skipped test. All 12 listening-position instrumentation tests passed on the Android 16 Pixel 7a emulator, including both real menu entry points, camera preview/release, image boundaries and profile/copy isolation. The final debug APK was installed and cold-started without fatal or class-loading errors. Camera, camera-any and autofocus declarations were verified optional in APK badging. Provenance verification passed.

The acknowledgements inventory includes ZXing Core and ONNX Runtime Android. `verifyAcknowledgementsInventory` checks it against the resolved release dependencies; ZXing's Apache-2.0 text is also bundled as a separate acknowledgement.

For ordinary EPUBs opened in Readium, a CFI-only checkpoint is resolved against the local publication before restore. Existing DOM and text anchors take precedence; an unresolvable CFI leaves the saved fallback location intact. Read-aloud opening is unchanged.
