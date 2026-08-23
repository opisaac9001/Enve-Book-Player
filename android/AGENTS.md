# Enve Agent Instructions

Read `CLAUDE.md` and `DEVELOPMENT.md` before inspecting or changing application code. These rules apply to every coding agent, regardless of vendor or model name.

Everything here is scoped to the Android app and every path is relative to this Android root. If the checkout nests this tree beside a sibling platform, that platform has its own instructions — follow the ones that own the files you are touching.

## Before changing code

Confirm that the shell is at the Android root and inspect the current checkout:

```sh
pwd
git rev-parse --show-toplevel
git branch --show-current
git status --short
```

Preserve unrelated changes. Do not switch branches, push, merge, rewrite history, or create a pull request unless the person directing the work explicitly asks.

## Agent-locked files

Files whose first line is exactly `// AGENT-LOCKED` are protected by a user-owned advisory lock.

When a task might involve one of those files:

1. Read only the first line. Do not search, print, summarize, diff, or inspect the rest of the file yet.
2. Run `./scripts/agent-lock status`.
3. If it reports `not configured`, stop work on the protected file and ask the user to create a password with `./scripts/agent-lock set`.
4. If it reports `configured`, ask the user for the password before continuing. A user who does not want to put the password in chat may run `./scripts/agent-lock verify` themselves and explicitly authorize the protected work after it succeeds.
5. Verify the supplied password with `./scripts/agent-lock verify`. Never echo it, include it in a command argument, store it in a repository file, log it, or repeat it back.
6. Successful verification applies only to the protected files needed for the current user request and only for the current agent turn.
7. A failed or missing password means the file remains unread and unchanged. Work around it if possible or report the block.

The local `.agent-lock` file contains a salted hash and is ignored by Git. It is never committed. The lock is a cooperation rule, not encryption or an access-control boundary. A person with filesystem access can remove it, so do not describe it as tamper-proof security.

Protected paths:

- `app/src/main/java/com/enve/app/ui/auth/AuthBrowserActivity.kt`
- `app/src/main/java/com/enve/app/ui/auth/AuthViewModel.kt`
- `app/src/main/java/com/enve/app/ui/screens/ServiceLoginAdvancedOptions.kt`
- `app/src/main/java/com/enve/app/ui/screens/ServiceLoginScreen.kt`
- `audiobookshelf/src/main/java/com/enve/audiobookshelf/auth/AbsOidcFlow.kt`
- `audiobookshelf/src/main/java/com/enve/audiobookshelf/auth/AbsPasswordLogin.kt`
- `audiobookshelf/src/main/java/com/enve/audiobookshelf/auth/AbsTokenRefreshStrategy.kt`
- `bookorbit/src/main/java/com/enve/bookorbit/auth/BookOrbitAuthCookies.kt`
- `bookorbit/src/main/java/com/enve/bookorbit/auth/BookOrbitOidcFlow.kt`
- `bookorbit/src/main/java/com/enve/bookorbit/auth/BookOrbitPasswordLogin.kt`
- `bookorbit/src/main/java/com/enve/bookorbit/auth/BookOrbitTokenRefreshStrategy.kt`
- `core/src/main/java/com/enve/core/auth/AbsOidcPkce.kt`
- `core/src/main/java/com/enve/core/auth/CredentialVault.kt`
- `core/src/main/java/com/enve/core/auth/OAuthRedirectUris.kt`
- `core/src/main/java/com/enve/core/data/local/PreferencesManager.kt`
- `core/src/main/java/com/enve/core/data/remote/auth/AuthInterceptor.kt`
- `core/src/main/java/com/enve/core/data/remote/auth/ConnectionAuthHeaders.kt`
- `core/src/main/java/com/enve/core/data/remote/auth/TokenRefreshAuthenticator.kt`
- `core/src/main/java/com/enve/core/data/remote/security/PrivateNetworkTrust.kt`
- `engine/src/main/java/com/enve/app/auth/MtlsManager.kt`
- `engine/src/main/java/com/enve/app/data/auth/GrimmoryTokenRefreshStrategy.kt`
- `engine/src/main/java/com/enve/app/data/emby/EmbyPasswordLogin.kt`
- `engine/src/main/java/com/enve/app/data/grimmory/auth/GrimmoryOidcFlow.kt`
- `engine/src/main/java/com/enve/app/data/grimmory/auth/GrimmoryPasswordLogin.kt`
- `engine/src/main/java/com/enve/app/data/jellyfin/JellyfinPasswordLogin.kt`
- `engine/src/main/java/com/enve/app/data/jellyfin/JellyfinQuickConnectFlow.kt`
- `engine/src/main/java/com/enve/app/data/kavita/KavitaPasswordLogin.kt`
- `engine/src/main/java/com/enve/app/data/mediabrowser/MediaBrowserPasswordAuthenticator.kt`
- `engine/src/main/java/com/enve/app/data/opds/BasicSourcesPasswordLogin.kt`
- `komga/src/main/java/com/enve/komga/auth/KomgaOAuthFlow.kt`
- `komga/src/main/java/com/enve/komga/auth/KomgaPasswordLogin.kt`
- `local/src/main/java/com/enve/local/auth/LocalPasswordLogin.kt`
- `plex/src/main/java/com/enve/plex/auth/PlexAuthHeaderStrategy.kt`
- `plex/src/main/java/com/enve/plex/auth/PlexPinAuthFlow.kt`
- `plex/src/main/java/com/enve/plex/auth/PlexPinAuthService.kt`
- `silo/src/main/java/com/enve/silo/auth/SiloPasswordLogin.kt`
- `silo/src/main/java/com/enve/silo/auth/SiloTokenRefreshStrategy.kt`
- `storyteller/src/main/java/com/enve/storyteller/auth/StorytellerAuthHeaderStrategy.kt`

Do not add or remove a protected marker without the user's explicit approval.

## Implementation rules

- Keep changes inside the requested scope.
- Prefer existing structures over new layers.
- Put provider integrations in their provider modules, backend orchestration in `:engine`, shared storage and network infrastructure in `:core`, and UI-facing contracts in `:engine-api`.
- Use Hilt multibindings as the provider and strategy registry.
- Do not add state to `AggregatorRepository`, `SyncCoordinator`, or a provider repository when a focused service or store is appropriate.
- Keep prose comments and section banners out of first-party Kotlin. The `// AGENT-LOCKED` marker is the standing exception.
- Never log credentials, authorization headers, tokens, cookies, signed URLs, or private server addresses.
- Preserve the module, transport, and credential-storage invariants in `CLAUDE.md`.
- Inspect every diff and remove placeholders, redundant explanations, speculative abstractions, and unrelated cleanup.

## Verification

The person submitting or directing the change owns final verification. Generated code is not proof that a task works.

- Run unit tests plus debug and minified release builds.
- Confirm zero errors and zero new warnings.
- Install and launch the app for runtime changes.
- Exercise the changed workflow on a supported device.
- Run `./scripts/verify-provenance` after changing protected markers, licensing, notices, provenance, or bundled assets.

See `CONTRIBUTING.md`, `SECURITY.md`, and `AI_POLICY.md` for the public contribution rules.
