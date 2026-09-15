# Security Policy

## Reporting a vulnerability

Please do not open a public issue for an unpatched vulnerability. Use GitHub's private security advisory feature for this repository, or email `enve.audiobook@gmail.com` if private advisories are unavailable.

Include the affected version, reproduction steps, impact, and any suggested mitigation. Remove real credentials, tokens, server addresses, library metadata, and book files from logs or screenshots.

You should receive an acknowledgement within seven days. Fix timing depends on severity, reproducibility, and whether the issue is in Enve or an upstream dependency.

## Supported versions

Security fixes are made against the current `main` branch. Older releases may receive a fix when practical, but are not guaranteed long-term support.

## Security-sensitive invariants

Enve connects to servers chosen and operated by the user. This creates a different boundary from an app that talks only to one managed HTTPS service.

- Credentials and refresh tokens belong in Keychain, never UserDefaults or source files.
- Tokens must not be written to logs or diagnostics.
- Non-streaming API requests should prefer authorization headers.
- Some AVPlayer and image URLs carry provider tokens because those framework paths cannot reliably attach custom headers. This is documented and intentional.
- Local-network self-signed TLS is supported only for hosts recognized as local by `NetworkHostUtils`.
- `NSAllowsArbitraryLoads` is required for user-supplied LAN and self-hosted servers. Changing it requires end-to-end testing across supported providers.
- OAuth client identifiers belong in the ignored `DeveloperSettings.plist`; client secrets do not belong in a distributed iOS app.

Changes to these invariants require provider-level verification against the affected server configurations.
