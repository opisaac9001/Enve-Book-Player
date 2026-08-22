# RAR Support Provenance

Verified: 2026-08-08

## Swift adapter

`Package.swift` and `Sources/UnrarKit/RARArchive.swift` are Enve's project-local Swift Package Manager adapter around the UnRAR C API. They are not a vendored revision of [abbeycode/UnrarKit](https://github.com/abbeycode/UnrarKit), so no upstream wrapper commit applies.

The Dov Frankel BSD-style notice in `LICENSE` is retained from the package's earlier UnrarKit identification. It does not replace the separate UnRAR license in `license.txt`.

## UnRAR source

- Upstream: [RARLAB UnRAR source](https://www.rarlab.com/rar_add.htm)
- Source release: UnRAR 6.1.7
- Binary and API version: 6.12
- Release date: 2022-05-04
- Upstream archive: `unrarsrc-6.1.7.tar.gz`
- Archive SHA-256: `de75b6136958173fdfc530d38a0145b72342cf0d3842bf7bb120d336602d88ed`
- License: UnRAR freeware license in `license.txt`

All 147 files copied from the portable source archive match UnRAR 6.1.7 byte for byte. RARLAB identifies this source as the implementation for binary and API version 6.12, which is embedded in `Sources/unrar-lib/version.hpp` with the date 2022-05-04. RARLAB distributes UnRAR as release archives rather than an authoritative Git repository, so a Git commit does not apply. `Sources/unrar-lib/include/unrar.h` is the project-local C module interface and is not part of the upstream archive.

The Swift package compiles the extraction API and excludes compression and command-line files in `Package.swift`. Redistribution must retain the full UnRAR license paragraph that prohibits using this source to recreate the proprietary RAR compression algorithm.
