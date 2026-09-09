# Public Release Model

This repository contains public source snapshots of Enve Book Player. Active development takes place in a separate private repository.

Each public update is prepared from a reviewed development revision and published as a clean snapshot. The public repository does not mirror private development history, temporary branches, credentials, signing material, or internal release notes. Snapshots may include features ahead of their app-store release; the changelog records known verification limits.

## What to expect

- `main` represents the latest public source snapshot.
- Version tags identify the source corresponding to public app releases.
- Release notes describe user-visible changes and known limitations.
- Urgent public fixes may land between app releases when needed.
- Pull requests are reviewed against the current public source and may be integrated into a later stable release.

Published snapshots are expected to include the files required to build the public version, subject to developer-owned signing, bundle identifiers, entitlements, and optional OAuth configuration.
