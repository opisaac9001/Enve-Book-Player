# libmobi Provenance

Verified locally: 2026-08-28

- Upstream: https://github.com/bfabiszewski/libmobi
- Declared release: 0.12
- Imported upstream commit: `906274205c11944b628da1c553b255acb1af7c55`
- Upstream source archive SHA-256: `ec260e472d4db1bcbf8c479ee470bd2a2b2b822f14313604c76e667a684e1dfa`
- License: LGPL-3.0-or-later
- Enve import: present in the first Android repository commit

The vendored tree matches upstream commit `906274205c11944b628da1c553b255acb1af7c55`, whose `configure.ac` declares version 0.12, except for these Android integration changes:

- the top-level CMake file does not build the command-line tools
- `src/encryption.h` includes `buffer.h` explicitly for the Android build
- this provenance file is added

The comparison was made file-for-file against the upstream Git tree after correcting four accidental documentation-word substitutions in vendored comments. Do not update or redistribute this directory without retaining `COPYING`, updating this record, and satisfying the binary requirements in the root third-party audit.
