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

## Guides

- [guides/automation.md](guides/automation.md) — Tasker and broadcast-intent playback control

## Testing

- [testing/manual-test-plan.md](testing/manual-test-plan.md) — on-device checklist for release verification

## Release

- [release/play-tip-jar.md](release/play-tip-jar.md) — Google Play one-time product setup for the tip jar
- [legal/THIRD_PARTY_AUDIT.md](legal/THIRD_PARTY_AUDIT.md) — third-party obligations that gate binary distribution
