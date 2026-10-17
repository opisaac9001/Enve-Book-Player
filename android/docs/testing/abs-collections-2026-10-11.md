# Audiobookshelf collections verification — 2026-10-11

## Reproduction

Authenticated against the documented Audiobookshelf lab server. Across all three libraries, requesting collections with an Enve connection-scoped library identifier returned HTTP 404. The same request with the remote library UUID returned HTTP 200. The `limit=500` query was accepted.

## Android verification

The repository normalizes library identifiers before collection reads and collection creation. Connection scope continues to select the server and account.

- Four identifier unit tests passed, covering raw UUIDs, scoped IDs, legacy scoped IDs, and IPv6/account separators.
- Debug and minified release builds passed.
- `PublicSourceRegressionTest.audiobookshelfCollectionsUseRemoteLibraryIds` passed on Pixel 7a. It exercised the real repository and transport against a recording fixture, checking both collection GET paths and the collection POST body.
- `PublicSourceRegressionTest.audiobookshelfCollectionsLoadFromLiveServer` passed on Pixel 7a against all three lab libraries. It passed once with empty collections and again with a temporary collection containing one existing book. Returned collection IDs matched the server response.

The live test requires a private fixture in the debug app's files directory and skips when it is absent. No server addresses or credentials are stored in source. The temporary collection was deleted successfully, all libraries returned to their original empty collection state, and the private fixture was removed from both the device and Mac. The test uses an isolated profile and clears that profile's credentials and storage afterward.

This verifies the Android collection request and response flow. It does not certify the iOS implementation or unrelated playback and reader behavior. No changes were committed or pushed.
