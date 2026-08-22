# Contributing to Enve Book Player

Focused fixes, provider improvements, accessibility work, documentation, and well-scoped features are welcome.

## Before writing code

1. Search the existing issues and pull requests.
2. Open an issue before starting a large feature, architecture change, new dependency, or new backend.
3. Keep each contribution focused on one problem.
4. Build the unmodified app first so existing failures are not mistaken for regressions.

## Project conventions

- Use idiomatic Swift 6 and the project's MainActor-default isolation.
- Prefer clear names and small focused types. Comment reasoning, compatibility constraints, protocol details, and non-obvious workarounds when the code alone cannot explain them.
- Do not add section banners or comments that narrate obvious code.
- Do not add placeholder code or speculative abstractions.
- Follow the existing feature, provider, persistence, and service boundaries.
- Match the app's established visual language and accessibility behavior.
- Never weaken network, credential-storage, signing, or entitlement behavior without discussing it first.

## Privacy and secrets

Never commit or paste into an issue:

- passwords, API keys, authorization headers, or refresh tokens
- private server addresses or signed media URLs
- downloaded books, personal covers, or library databases
- diagnostic exports containing user or server data
- populated developer settings or signing files

Use invented values in tests and reports. Remove the entire secret rather than leaving a recognizable prefix.

## Verifying a change

Before opening a pull request:

1. Review the complete diff for unrelated changes, temporary files, and private data.
2. Build the `enve` scheme on an Apple-silicon iOS Simulator.
3. Run the `AllTests` plan for changes to testable application behavior.
4. Confirm there are no new errors or warnings.
5. Install and launch the app for runtime changes.
6. Exercise every affected user-facing path with representative data.
7. Build any other target affected by the change.
8. Update documentation when setup, behavior, architecture, or security assumptions change.

## Pull requests

Include:

- the problem and user-visible outcome
- the important implementation choice, when one exists
- exact build and runtime checks performed
- screenshots or a short recording for visible UI changes
- known limitations or follow-up work

By contributing, you confirm that you have the right to submit the work and agree to the contribution terms in [LICENSE.md](LICENSE.md).
