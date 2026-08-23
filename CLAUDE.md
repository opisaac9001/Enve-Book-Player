# Enve Book Player Repository Guide

This repository contains two native applications:

- `ios/` — Swift 6, SwiftUI, Readium, iPhone/iPad, Watch, widgets, and tvOS
- `android/` — Kotlin, Compose, Hilt, Media3, Readium, and Wear OS

Before changing application code, enter the owning platform directory and read its `CLAUDE.md`, `AGENTS.md`, and `DEVELOPMENT.md` completely. Platform instructions do not cross directory boundaries.

Shared repository files at the root cover contribution policy, security reporting, licensing, community health, publishing, screenshots, and GitHub automation. Keep platform implementation and platform-specific documentation inside `ios/` or `android/`.

Do not move code between platforms merely to make their trees look identical. Preserve their shared product vocabulary and behavior while using idiomatic platform architecture.

Generated work remains a draft until Codex or a human maintainer reviews the diff and runs the owning platform's authoritative build, tests, and runtime checks.
