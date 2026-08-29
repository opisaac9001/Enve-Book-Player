# whisper.cpp Provenance

Verified locally: 2026-08-28

- Upstream: https://github.com/ggml-org/whisper.cpp
- Declared release: 1.8.4
- Upstream tag commit: `9386f239401074690479731c1e41683fbbeac557`
- License: MIT
- Enve import commit: `56edd8f993f27ad39bccd11a404bb04e596e2b96`

Every vendored whisper.cpp and ggml file was compared by Git blob hash with tag `v1.8.4` at commit `9386f239401074690479731c1e41683fbbeac557`. `whisper.cpp`, `whisper.h`, and `whisper-arch.h` retain their upstream content with the repository's flattened layout; the remaining files retain their upstream paths. The only additional files in this directory are this provenance record.

The `enve_whisper.cpp` JNI bridge is Enve-owned adapter code based on the upstream Android JNI example. Retain the upstream MIT notice with source and binary distributions.
