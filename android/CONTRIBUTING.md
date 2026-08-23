# Contributing to Enve Book Player for Android

Focused fixes, provider improvements, accessibility work, documentation, and well-scoped features are welcome.

Read `DEVELOPMENT.md` before starting, and `docs/README.md` for anything deeper. Coding agents must also read `AGENTS.md` and follow its protected-file password process. Security reports belong in the private process described in `SECURITY.md`, not in a public issue.

These rules cover the Android app. If the checkout nests it beside a sibling platform, say which platform a change targets in the issue or pull-request title, and keep one change to one platform.

## Before writing code

1. Search existing issues and pull requests for related work.
2. Open an issue before a large feature, architecture change, new dependency, or new backend.
3. Keep one contribution about one thing. Leave unrelated refactors for their own change.
4. Build the existing app before editing so old failures are not confused with new ones.

## Project conventions

- Use idiomatic Kotlin, structured concurrency, StateFlow, and Compose state hoisting.
- Prefer clear names and focused types over explanatory comments.
- Do not add prose comments, KDoc, section banners, placeholders, or speculative abstractions to first-party Kotlin files.
- Preserve the first-line `// AGENT-LOCKED` marker on protected files.
- Keep the `hearth-ui` dependency wall intact. UI code reaches the backend only through `engine-api` facades.
- Provider modules depend on `core`, not on each other, `engine`, or `app`.
- Do not add unrelated state to `AggregatorRepository`, `SyncCoordinator`, or provider repositories.
- Use Hearth design values rather than hard-coded UI colors.

## Privacy and secrets

Never commit or paste into an issue:

- credentials, API keys, authorization headers, refresh tokens, or cookies
- private server addresses or signed media URLs
- downloaded books, covers without redistribution rights, or library databases
- diagnostic exports containing user or server data
- `local.properties`, signing keystores, signing passwords, or `.agent-lock`

Use invented values in tests. Redact the entire secret rather than leaving a recognizable prefix.

## Verification

Before opening a pull request:

1. Review the entire diff for scope, generated noise, and private data.
2. Run `./gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease`.
3. Confirm zero errors and zero new warnings.
4. Install and launch the debug APK on a supported device for runtime changes.
5. Exercise every changed user-facing path with representative data. `docs/testing/manual-test-plan.md` lists the flows per area.
6. Run `./scripts/verify-provenance`.
7. Update public documentation when setup, architecture, behavior, or security assumptions change.

Automated output is not verification. Disclose meaningful AI assistance in the pull request as described in `AI_POLICY.md`.

## Pull requests

Explain the user-visible outcome, important implementation choices, exact verification performed, known limitations, and meaningful AI assistance. Do not rewrite a maintainer's branch or include unrelated formatting.

By contributing, you agree that your contribution is distributed under `LICENSE.md` as described in its contribution section.
