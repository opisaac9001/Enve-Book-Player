# Public source publication

The production Android repository is the working copy. The public `opisaac9001/Enve-Book-Player` repository receives a reviewed snapshot of this repository's publishable source in its `android/` directory when the app is released.

The published snapshot must correspond to the production binary. Features that are still being prepared may exist only in the working repository, but every feature shipped in the Play release must be present in the public snapshot. This includes Android Auto support, its media-library implementation, artwork provider, resources, manifest declarations, tests, and related playback code.

Before publishing:

1. Complete the private repository's release gate and build the exact production candidate.
2. Export all publishable source, documentation, notices, and build files into the public repository's `android/` directory.
3. Exclude only credentials, signing material, local configuration, build output, user media, diagnostics, and private Git metadata.
4. Review the complete public diff and confirm that Android Auto and every other shipped feature are represented.
5. Build and test the exported public snapshot independently.
6. Record the private revision, public revision, release version, and production artifact digest in the release evidence.

The public snapshot is not a substitute for the source and relinking materials required by individual third-party licenses. Those materials must be generated from and verified against the exact production artifact.
