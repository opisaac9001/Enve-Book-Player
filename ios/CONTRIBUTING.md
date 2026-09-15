# Contributing to Enve Book Player

Thank you for helping improve Enve. Focused fixes, provider improvements, accessibility work, documentation, and well-scoped features are welcome.

Read `DEVELOPMENT.md` before starting. Security reports belong in the private process described in `SECURITY.md`, not in a public issue.

## Before writing code

1. Search existing issues and pull requests for related work.
2. For a large feature, architecture change, new dependency, or new backend, open an issue first and describe the user need and proposed scope.
3. Keep one contribution about one thing. Separate drive-by refactors from the change that motivated them.
4. Build the existing app before editing so pre-existing failures are not confused with your work.

## Project conventions

- Use idiomatic Swift 6 and the project's MainActor-default isolation.
- Prefer clear names and small focused types. Comment reasoning, compatibility constraints, protocol details, and non-obvious workarounds when the code alone cannot explain them.
- Do not add comments that narrate obvious code, generated section banners, placeholders, or speculative abstractions.
- Put backend implementations in `enve/Networking/`, persistence in `enve/Persistence/`, plugin contracts in `enve/Plugins/`, and focused domain services in `enve/Services/`.
- Do not add unrelated state to `AppState`, `SyncCoordinator`, or `StorageService`.
- Use the existing Hearth design tokens and presentation conventions for SwiftUI work.
- Do not silently change the network and entitlement invariants documented in `SECURITY.md`.

## Privacy and secrets

Never commit or paste into an issue:

- account credentials, API keys, authorization headers, or refresh tokens
- private server addresses or signed media URLs
- downloaded books, covers without redistribution rights, or library databases
- diagnostic exports containing user or server data
- populated `DeveloperSettings.plist` files

Use invented values in tests and reports. Redact the entire secret rather than leaving a recognizable prefix.

## Verification

Before opening a pull request:

1. Review the entire diff for scope, generated noise, and accidental private data.
2. Build the `enve` scheme on an Apple-silicon iOS simulator.
3. Run the `AllTests` plan for changes to testable application behavior.
4. Confirm zero errors and zero new warnings.
5. Install and launch the app for runtime changes.
6. Exercise every changed user-facing path with representative data.
7. Build other affected targets separately.
8. Run `./scripts/verify-provenance`.
9. Update public documentation when setup, behavior, architecture, or security assumptions changed.

Tool output is not verification. Contributors own every submitted line and must understand, review, build, and exercise their changes.

## Pull requests

The description should include:

- the user-visible problem and outcome
- the important implementation choice, if one exists
- the exact build and runtime checks performed
- screenshots or a short recording for visible UI work
- known limitations or follow-up work

Keep commits readable and focused. Do not rewrite a maintainer's branch, include unrelated formatting, or add generated files that the project does not track.

## Contribution licensing

Contributions are accepted on an inbound-equals-outbound basis. By intentionally submitting a contribution, you license it under the GNU Affero General Public License v3.0 only (`AGPL-3.0-only`) in `LICENSE.md`. You retain ownership of your contribution. No separate contributor agreement grants Enve broader relicensing rights unless you separately agree to one in writing.
