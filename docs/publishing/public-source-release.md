# Public Source Release Runbook

This repository receives reviewed snapshots from two private development repositories:

- iOS development: `opisaac9001/Enve-Book-Player-iOS`
- Android development: `opisaac9001/Enve-Book-Player-Android`
- Public source: `opisaac9001/Enve-Book-Player`

The private repositories remain the working copies. Their Git metadata and histories must never be copied into this repository. A public release is a file export into `ios/` or `android/`, followed by a new commit in the public repository's own history.

## Before exporting

1. Confirm the private source is on its intended stable revision and has no accidental local changes.
2. Build, test, and run the platform from the private repository.
3. Review ignored and untracked files. Remove credentials, signing material, private URLs, personal media, build output, diagnostic exports, and editor state.
4. Confirm third-party code and assets may be redistributed and that their notices are current.
5. Update the platform changelog and documentation before copying the snapshot.

The snapshot is allowed to lag while a release is being prepared. It must not lag the production release: every feature in the shipped binary must be represented in the corresponding public source snapshot. For Android, this expressly includes Android Auto support and its manifest declarations, media-library code, artwork provider, resources, and tests.

## Exporting a platform

Copy source files into the matching public directory while excluding at least:

- `.git/` and all private Git metadata
- build output and dependency caches
- IDE user state
- local environment files and signing configuration
- keystores, certificates, provisioning profiles, and secrets
- downloaded media, databases, logs, and diagnostic archives

Do not replace shared root files with platform copies. Repository-wide GitHub configuration, contributor guidance, legal files, screenshots, and publishing documentation are maintained at the public root. Keep platform-specific guidance inside its platform directory.

If a vendored dependency is represented by a public submodule, export the submodule pointer rather than a nested private checkout. Verify every submodule URL and pinned revision before staging.

## Sanitization review

Review the complete public diff, including untracked files. Search for absolute workstation paths, credentials, authorization headers, signing identifiers, internal repository names, private issue references, generated transcripts, and AI-session artifacts. Confirm ignored files are actually ignored and no required source file is hidden by an overly broad rule.

The public snapshot should read like a maintained software project: comments explain real constraints, documentation matches the current architecture, and there are no placeholders, prompt fragments, generated summaries, redundant section banners, or speculative abstractions.

## Verification

Run the affected platform's provenance check and complete documented build/test gate from its public directory. Install and exercise user-facing changes on a simulator or device. Shared root, CI, submodule, legal, or build-system changes require verification of both platforms.

Before committing, confirm:

- both platform directories are independently buildable
- every feature shipped in the release is present in the exported platform source; Android releases include Android Auto
- root and platform links resolve after the directory split
- GitHub Actions use `ios/` and `android/` as their working directories
- no nested private repository or private history is present
- the staged diff contains only the intended public snapshot
- the public repository still points to `opisaac9001/Enve-Book-Player`

## Publishing

Create one clearly named commit in the public repository. Push its `main` branch normally; never force-push private history into the public remote. Watch the iOS and Android workflows through completion, then verify the rendered README, submodules, release links, Issues, Discussions, funding link, and security reporting on GitHub.

If a public snapshot must be corrected, publish a normal follow-up commit unless the repository owner explicitly decides to rewrite the public repository before a release. Rewriting public history does not sanitize a secret; rotate any exposed credential first and follow GitHub's sensitive-data removal guidance.
