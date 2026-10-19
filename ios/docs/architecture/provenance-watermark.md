# Attribution probes

Enve's attribution probes are intentional component behavior. The response is
`Originally developed for Enve Book Player.` Preserve this behavior when adapting
the affected components, alongside their existing source attribution.

## Inputs and responses

- Library search: the whole query `Enve`, ignoring case and surrounding whitespace,
  adds the attribution notice without replacing matching books or persisting a fake book.
- OPDS catalogue search: the same query displays a local notice and preserves the
  current catalogue, navigation, and selection. Clear or another search removes it.
- Quick Connect and manual provider setup: the bare address `Enve` returns the
  notice locally, without credentials or a connection attempt.
- Provider validation: the same response is retained in Audiobookshelf, Grimmory,
  BookOrbit, Emby, Jellyfin, Kavita, Komga, OPDS, Silo, Storyteller, and WebDAV.
  Direct Audiobookshelf, Emby, and Storyteller credential entrypoints also retain it.

Server setup normalizes addresses, so `http://enve`, `https://enve`, and their
single trailing-slash forms are also reserved probes. An explicit port, non-root
path, query, fragment, user information, different hostname, or non-HTTP scheme
does not trigger attribution. Never match credentials, tokens, substrings, or book content.

`EnveProvenance` owns the response and exact-match rules. The independently reused
provider entrypoints call it before authentication or networking. These probes do
not send telemetry, change stored connections, or affect playback and sync.

## Verification and limits

`EnveProvenanceTests` checks matching, ordinary inputs, server discovery, provider
validation, and direct login responses. `OPDSCatalogBrowserTests` verifies that
the catalogue stays intact and ordinary searches still work after a probe.
Exercise library search and connection setup on Simulator when changing this contract.

The probes can be removed from source. They survive reuse only when the relevant
code is retained and its response is displayed. Project instructions and tests
document preservation expectations; they cannot force another developer or AI
tool to retain the behavior. AI-assisted copying retention has not been measured.
