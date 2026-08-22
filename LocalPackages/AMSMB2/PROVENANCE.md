# AMSMB2 Provenance

Verified: 2026-08-08

## AMSMB2

- Upstream: [amosavian/AMSMB2](https://github.com/amosavian/AMSMB2)
- Release: `4.0.3`
- Commit: `1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0`
- License: MIT for the Swift wrapper, combined with the separately listed LGPL libsmb2 dependency

Every package file outside `Dependencies/libsmb2/` matches the upstream `4.0.3` tree byte for byte. The local `.swiftpm/` directory is Xcode workspace metadata and is not part of the upstream release.

## libsmb2

- Upstream: [sahlberg/libsmb2](https://github.com/sahlberg/libsmb2)
- Commit: `aff9fa6ba9f41cfd3c15d184554601ec3f6d8d03`
- Commit date: 2025-08-09
- License: LGPL-2.1-or-later for the library and headers; BSD-2-Clause for examples

The commit is the `Dependencies/libsmb2` submodule revision recorded by AMSMB2 4.0.3. All 193 files in the local libsmb2 directory match that revision byte for byte.

Do not update either component without updating this file, retaining the applicable license texts, and rechecking the binary-distribution requirements in the root `THIRD_PARTY_NOTICES.md`.
