# Publishing

Public releases are reviewed snapshots from the private iOS and Android development repositories. A snapshot transfers sanitized files, never either private repository's `.git` directory or commit history.

Keep platform exports isolated, preserve shared root policy and community files, run both affected CI workflows, and verify the public checkout before pushing. Changes limited to one platform require that platform's full build and tests; shared changes require both.

Follow the [public source release runbook](public-source-release.md) for the complete copy, sanitization, verification, and publication procedure.
