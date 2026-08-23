# Enve Book Player Agent Router

This file routes coding agents to the correct platform instructions.

## Before changing code

From the repository root, confirm the checkout and preserve any existing work:

```sh
pwd
git remote get-url origin
git branch --show-current
git status --short
```

Then follow the owning tree:

- iOS, iPadOS, watchOS, widgets, or tvOS: read `ios/CLAUDE.md`, `ios/AGENTS.md`, and `ios/DEVELOPMENT.md`.
- Android or Wear OS: read `android/CLAUDE.md`, `android/AGENTS.md`, and `android/DEVELOPMENT.md`.
- Shared documentation, GitHub configuration, licensing, or screenshots: follow this file plus the applicable platform guides when platform details are involved.

Agent-lock authorization is platform-local and turn-local. Follow the protected-file protocol in the owning platform's `AGENTS.md`; authorization for one platform does not grant access to protected files in the other.

Do not commit, push, merge, rewrite history, or change branches unless the user explicitly requests it. Review and verify all generated changes before publication.
