# whisper.cpp Provenance

Verified locally: 2026-08-10

- Upstream: https://github.com/ggml-org/whisper.cpp
- Declared release: 1.8.4
- License: MIT
- Enve import commit: `56edd8f993f27ad39bccd11a404bb04e596e2b96`

The Android CMake configuration pins the compiled version string to 1.8.4. The original upstream commit was not recorded with the import and must be established before distributing a binary.

The `enve_whisper.cpp` JNI bridge is Enve-owned adapter code based on the upstream Android JNI example. Retain the upstream MIT notice with source and binary distributions.
