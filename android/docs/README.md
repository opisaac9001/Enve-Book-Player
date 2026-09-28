# Enve Book Player for Android — Documentation

Reference material for the Android app. Start with the root files for anything that applies to the whole repository:

- [README.md](../README.md) — what the app is, requirements, build steps
- [DEVELOPMENT.md](../DEVELOPMENT.md) — setup, project shape, common changes, verification
- [CONTRIBUTING.md](../CONTRIBUTING.md) — contribution rules and pull-request expectations
- [SECURITY.md](../SECURITY.md) — vulnerability reporting and security invariants
- [CLAUDE.md](../CLAUDE.md) and [AGENTS.md](../AGENTS.md) — the rules coding agents must follow
- [AI_POLICY.md](../AI_POLICY.md) — what AI-assisted contributions must satisfy

## Architecture

- [architecture/module-boundaries.md](architecture/module-boundaries.md) — Gradle module layout, the UI/backend dependency wall, and the boot contract
- [architecture/engine-api.md](architecture/engine-api.md) — the facade contract the Compose UI is allowed to call
- [architecture/eink.md](architecture/eink.md) — e-ink detection, refresh policy, and how the design system degrades on EPD panels
- [architecture/opds-catalog.md](architecture/opds-catalog.md) — OPDS 1.2 and 2.0 catalog structure, crawl, search, acquisition, and OPDS Authentication 1.0
- [architecture/koreader-sync.md](architecture/koreader-sync.md) — KOSync transport rules, document matching across KOReader and CrossPoint, and XPointer conversion
- [architecture/opds-progression.md](architecture/opds-progression.md) — discovery, transport, references, and merge rules for the OPDS Progression 1.0 draft

## Guides

- [guides/automation.md](guides/automation.md) — Tasker and broadcast-intent playback control
- [guides/readium-lcp-integration.md](guides/readium-lcp-integration.md) — private runtime handoff, acquisition boundaries, and certification gate for Readium LCP

## Testing

- [testing/manual-test-plan.md](testing/manual-test-plan.md) — on-device checklist for release verification

## Release

- [release/play-tip-jar.md](release/play-tip-jar.md) — Google Play one-time product setup for the tip jar
- [release/play-console-submission.md](release/play-console-submission.md) — privacy, Data safety, Health apps, and store-asset submission record
- [release/lgpl-replacement.md](release/lgpl-replacement.md) — source, rebuilding, relinking, and installation instructions for LGPL components
- [release/public-source-publication.md](release/public-source-publication.md) — final source export and public verification for each production release
- [release/production-checklist.md](release/production-checklist.md) — exact local, public-source, Play Console, hardware, and rollout gates
- [legal/THIRD_PARTY_AUDIT.md](legal/THIRD_PARTY_AUDIT.md) — third-party obligations that gate binary distribution
