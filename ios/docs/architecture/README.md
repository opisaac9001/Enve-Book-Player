# Architecture Documents

The root [architecture guide](../../ARCHITECTURE.md) defines source ownership and dependency direction. The documents in this directory define cross-feature contracts that must remain stable as implementations evolve.

| Document | Scope |
|---|---|
| [Deduplication](deduplication.md) | Work grouping, edition selection, and merge behavior |
| [Download ownership](download-ownership.md) | Queue persistence, destination filesystem, and archive staging owners |
| [Comic library and reading cache](comic-library.md) | Offline availability, comic series hierarchy, reader return behavior, and bounded reading caches |
| [Identity contract](identity-contract.md) | Stable IDs and identity across providers, formats, and persistence |
| [Listening-position sharing](listening-position-sharing.md) | Public QR payload, canonical encoding, fixtures, matching and application rules |
| [Profiles implementation plan](profiles-plan.md) | Proposed adult and child profiles, storage isolation, migration, switching, and verification |
| [OPDS Authentication](opds-authentication.md) | Discovery, flows, token storage and retry for OPDS Authentication 1.0 |
| [OPDS catalog](opds-catalog.md) | Feed parsing, the browsable surface, search, acquisitions and fulfilment |
| [OPDS Progression](opds-progression.md) | Discovery, transport, references and conflict rules for the OPDS Progression 1.0 draft |
| [Provider capability matrix](provider-capability-matrix.md) | Supported backend capabilities and import behavior |
| [Server mirror contract](server-mirror-contract.md) | Catalog, activity, collection, deletion, and checkpoint semantics |

Feature presentation contracts live under [`docs/ui/`](../ui/). Backend wire references live under [`docs/reference/`](../reference/).
