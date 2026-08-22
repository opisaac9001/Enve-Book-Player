# Security Policy

## Reporting a vulnerability

Do not open a public issue for an unpatched vulnerability. Use [GitHub's private vulnerability reporting](https://github.com/opisaac9001/Enve-Book-Player/security/advisories/new) or email `enve.audiobook@gmail.com`.

Include the affected version, reproduction steps, impact, and any suggested mitigation. Remove real credentials, tokens, server addresses, library metadata, and book files from logs or screenshots.

You should receive an acknowledgement within seven days. Fix timing depends on severity, reproducibility, and whether the problem is in Enve or an upstream dependency.

## Supported versions

Security fixes target the current public `main` branch and latest release. Older releases may receive a fix when practical but are not guaranteed long-term support.

## Security boundaries

Enve connects directly to servers selected and operated by the user.

- Credentials and refresh tokens belong in Keychain, never source files or UserDefaults.
- Tokens must not be written to logs or diagnostics.
- Reports must not contain private server addresses, signed media URLs, or personal library data.
- Non-streaming API requests should prefer authorization headers. Some playback and image URLs carry provider tokens because those framework paths cannot reliably attach custom headers.
- Local self-signed TLS is supported only for recognized local hosts. `NSAllowsArbitraryLoads` is intentional for user-supplied LAN and self-hosted servers.
- OAuth client identifiers belong in ignored developer settings; client secrets do not belong in a distributed iOS app.
- Changes involving networking, local-server trust, media URLs, or entitlements require provider-level testing.
