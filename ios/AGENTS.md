# Enve Agent Instructions

Read `CLAUDE.md` and `DEVELOPMENT.md` before inspecting or changing Apple-platform code. These instructions govern the `ios/` tree; the sibling Android project has its own guides.

## Before doing anything

From the shared repository root, confirm:

```sh
pwd
git remote get-url origin
git branch --show-current
git status --short
```

Do not discard a dirty worktree. Do not switch branches, push, merge, rewrite history, or create a pull request unless the user explicitly asks.

## Agent-locked files

Files whose first line is exactly `// AGENT-LOCKED` are protected by a user-owned advisory lock.

When a requested task might involve one of those files:

1. Read only the first line. Do not search, print, summarize, diff, or inspect the rest of the file yet.
2. Run `./scripts/agent-lock status`.
3. If it reports `not configured`, stop work on the protected file and ask the user to create a password with `./scripts/agent-lock set`.
4. If it reports `configured`, ask the user for the password before continuing. A user who does not want to put the password in chat may run `./scripts/agent-lock verify` themselves and explicitly authorize the protected work after it succeeds.
5. Verify the supplied password with `./scripts/agent-lock verify`. Never echo it, include it in a command argument, store it in a repository file, log it, or repeat it back.
6. Successful verification applies only to the protected files needed for the current user request and only for the current agent turn.
7. A failed or missing password means the file remains unread and unchanged. Work around it if possible or report the block.

The local `.agent-lock` file contains a salted hash and is ignored by Git. It is never committed. The lock is a cooperation rule, not encryption or an access-control boundary. A person with filesystem access can remove it, so do not describe it as tamper-proof security.

Protected paths:

- `enve/Networking/ABSCredentials.swift`
- `enve/Networking/Providers/JellyfinProvider+Auth.swift`
- `enve/Screens/Sources/BrowserSessionLoginView.swift`
- `enve/Screens/Sources/KomgaLoginDelegate.swift`
- `enve/Screens/Sources/KomgaOAuthLoginView.swift`
- `enve/Screens/Sources/LoginDelegates.swift`
- `enve/Screens/Sources/UnifiedLoginContracts.swift`
- `enve/Services/CompanionReading/SharedKeychainStore.swift`
- `enve/Services/Network/MTLSManager.swift`
- `enve/Services/Network/NetworkPolicyService.swift`
- `enve/Services/Network/OAuthManager.swift`
- `enve/Services/Network/SecureTokenStorage.swift`
- `enve/Services/Network/ServerConfigStore.swift`
- `enve/Services/Network/SessionManager.swift`
- `enve/Services/Plex/PlexAuthStore.swift`
- `enve/Utilities/InsecureURLSession.swift`
- `enve/Utilities/KeychainHelper.swift`
- `enve/Utilities/NetworkHostUtils.swift`

Do not add or remove a protected marker without the user's explicit approval.

## Implementation rules

- Keep changes inside the requested scope.
- Prefer existing structures over new layers.
- Put provider integrations in `enve/Networking/`, state owners in `enve/Services/`, records and migrations in `enve/Persistence/`, and shared plugin contracts in `enve/Plugins/`.
- Do not add state to `AppState`, `SyncCoordinator`, or `StorageService` when a focused store is appropriate.
- Comment non-obvious constraints, protocol behavior, and workarounds when names cannot carry the reasoning. Remove comments that merely restate code or read like a generated walkthrough. Preserve every required `// AGENT-LOCKED` marker.
- Never log credentials, authorization headers, tokens, signed URLs, private server addresses, or diagnostic payloads containing them.
- Preserve the transport and entitlement invariants in `CLAUDE.md`.
- Inspect every diff and remove placeholder code, redundant explanation, speculative abstraction, and unrelated cleanup.

## Verification

Codex or the human maintainer owns final verification. A generated patch is not proof that a task works.

- Build the `enve` scheme for an Apple-silicon iOS simulator.
- Run the `AllTests` plan when changing testable application behavior.
- Confirm zero errors and zero new warnings.
- Install and launch the app for user-facing changes.
- Exercise the changed workflow instead of relying only on compilation.
- Run `./scripts/verify-provenance` before release-oriented commits.

See `ARCHITECTURE.md`, `../CONTRIBUTING.md`, and `../SECURITY.md` for source ownership and public contribution rules.
