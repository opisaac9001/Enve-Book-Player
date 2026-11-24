# BookBridge resume regression

When a book opens normally, Enve pulls the owner profile's KOReader position before it reconciles linked audiobook progress. Opening a bookmark or chapter uses the explicit destination. A pending offline edit or a newer local forward position takes precedence over an older server position.

BookBridge can return a KOReader XPointer or an EPUB CFI with a Unix timestamp in seconds. Enve resolves either locator against the local EPUB and falls back to the reported percentage when it cannot resolve one. It retains the server timestamp and persists progress even when the book is outside the current library window. [BookBridge KOSync implementation](https://github.com/cporcellijr/bookbridge/blob/main/src/api/kosync_server.py)

## Verification

`BookBridgeResumeTests` covers both locator formats, missing timestamps, cold-cache persistence, pending edits, explicit jumps and audiobook resume. The November 13 simulator run passed 2,174 tests with 39 skips. Live BookBridge checks covered authenticated reads and writes for both formats. A full handoff across a physical iPad, KOReader and Audiobookshelf remains unverified.
