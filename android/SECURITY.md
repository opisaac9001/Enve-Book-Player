# Security Policy

This policy covers the Enve Book Player Android app.

## Reporting a vulnerability

Do not open a public issue for an unpatched vulnerability. Use GitHub's private security advisory feature for this repository, or email `enve.audiobook@gmail.com` if private advisories are unavailable.

Include the affected platform and version, reproduction steps, impact, and any suggested mitigation. Remove real credentials, tokens, cookies, server addresses, library metadata, and book files from logs or screenshots.

Security fixes target the current `main` branch. Older releases are not guaranteed long-term support.

## Security-sensitive invariants

- Credentials belong in `CredentialVault`, never DataStore, ordinary preferences, or source files.
- Tokens, cookies, authorization headers, and signed URLs must not be logged.
- Non-streaming requests should use authorization headers when the provider supports them.
- User-supplied LAN servers and local self-signed TLS are intentional product requirements.
- Connection-scoped reads must use `ConnectionScope` aware resolvers so concurrent connections cannot borrow each other's credentials.
- Release HTTP logging stays at BASIC and must never expose authorization headers.
- OAuth applications and redirect URIs used by forks must belong to the fork maintainer.

Read `CLAUDE.md` before changing authentication, transport security, or connection scoping.

## Agent-locked source

Authentication, credential, session, and local TLS files carry a `// AGENT-LOCKED` first line. Coding agents must follow `AGENTS.md` and get user password authorization before reading or changing those files.

This is an advisory guard against accidental automated edits. It is not encryption and does not stop a person with filesystem access.
