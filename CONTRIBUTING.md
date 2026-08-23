# Contributing to Enve Book Player

Focused fixes, provider improvements, accessibility work, documentation, and well-scoped features are welcome.

Questions and early ideas belong in [GitHub Discussions](https://github.com/opisaac9001/Enve-Book-Player/discussions). Use Issues for reproducible bugs and work that is ready to be tracked. Report vulnerabilities privately through [GitHub's security advisory form](https://github.com/opisaac9001/Enve-Book-Player/security/advisories/new), never in an issue or discussion.

## Before writing code

1. Search the existing discussions, issues, and pull requests.
2. Start a discussion before committing to a large feature, architecture change, new dependency, or new backend. Once the scope is concrete, open an issue so the work can be tracked.
3. Keep each contribution focused on one problem.
4. Build the unmodified app first so existing failures are not mistaken for regressions.

## Fork and open a pull request

The quickest command-line workflow is:

```sh
gh repo fork opisaac9001/Enve-Book-Player --clone
cd Enve-Book-Player
git switch -c fix/short-description

# Make and verify your changes, then:
git push -u origin fix/short-description
gh pr create --repo opisaac9001/Enve-Book-Player --base main
```

You can also use GitHub's **Fork** button, clone your fork, create a focused branch, and open a pull request against this repository's `main` branch. The upstream repository intentionally keeps `main` as its only long-lived branch; contribution branches live in contributor forks and are deleted after merge. Maintainers may convert an Issue into a Discussion when the topic needs exploration before it becomes tracked work.

## Project conventions

- Follow the platform guide for the code you are changing: Swift 6 and MainActor-default isolation for Apple-platform code, or idiomatic Kotlin and structured concurrency for Android.
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
2. Build the affected platform: the `enve` scheme on an Apple-silicon iOS Simulator, or the Android Gradle targets documented in `android/DEVELOPMENT.md`.
3. Run the affected platform's unit and regression tests.
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
