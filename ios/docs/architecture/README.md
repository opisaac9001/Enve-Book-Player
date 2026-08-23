# Architecture Documents

The root [architecture guide](../../ARCHITECTURE.md) defines source ownership and dependency direction. The documents in this directory define cross-feature contracts that must remain stable as implementations evolve.

| Document | Scope |
|---|---|
| [Deduplication](deduplication.md) | Work grouping, edition selection, and merge behavior |
| [Identity contract](identity-contract.md) | Stable IDs and identity across providers, formats, and persistence |
| [Provider capability matrix](provider-capability-matrix.md) | Supported backend capabilities and import behavior |
| [Server mirror contract](server-mirror-contract.md) | Catalog, activity, collection, deletion, and checkpoint semantics |

Feature presentation contracts live under [`docs/ui/`](../ui/). Backend wire references live under [`docs/reference/`](../reference/).
