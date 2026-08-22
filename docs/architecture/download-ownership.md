# Download Ownership

`UnifiedDownloadService` is the scheduler for book downloads. It owns queue scheduling, task state and progress throttling, network gating, storage-limit decisions, provider plan execution, and background `URLSession` delegation. Everything it does not own is listed below, and it must not re-derive any of it inline.

## Owners

| Concern | Owner |
|---|---|
| Queue scheduling, task lifecycle, progress emission, cancel/retry/delete orchestration | `UnifiedDownloadService` |
| Persisted queue: storage key, encoding, finished-task retention on load | `UnifiedDownloadQueueStore` |
| Destination directory, chapter file naming, safe replacement, partial cleanup | `DownloadDestinationFileSystem` |
| Audiobook directory layout and downloaded-file discovery | `LocalStorageManager` |
| Archive detection, extraction, and multi-book distribution staging | `DownloadArchiveFileSystem` |
| Per-source download requests and post-processing | `DownloadPlanRegistry` and its `DownloadPlanProviding` implementations |
| Local file copy, SMB, and multi-track HTTP transfers | `BookDownloadManager` |

## Rules

- Only `LocalStorageManager` defines where audiobook files live. `DownloadDestinationFileSystem` is constructed with that root and sanitizes book identifiers through `LocalStorageManager.sanitizedId`. The root is injected rather than read from the singleton because the background `URLSession` delegate resolves destinations off the main actor.
- Downloaded audio is written as `chapter_<index>.<ext>` inside the book directory. `UnifiedDownloadService` and `DownloadArchiveFileSystem.extractZip` go through `DownloadDestinationFileSystem.chapterFile`. `BookDownloadManager`, `RARExtractor`, `StorytellerReadaloudOfflinePrep`, and `LocalStorageManager` still compose that name themselves, so the layout is a shared convention rather than a single enforced producer.
- Replacing a downloaded file is remove-then-move through `DownloadDestinationFileSystem.replaceItem`; a failed removal throws instead of leaving a stale destination in place. Failure paths clean up with `removeBookDirectory`, which reports whether a directory existed and throws when removal fails, so no caller logs a cleanup that did not happen.
- `DownloadArchiveFileSystem.extractZip` stages into an `archive-staging` subdirectory of the destination and removes it, plus the archive, before returning. Real-Debrid multi-book distribution uses `stageForDistribution` to move the archive out of the audiobook tree while each book's destination is cleared. Neither staging area survives a normal return, both can survive process termination, and nothing sweeps a leaked staging directory on relaunch.
- Multi-book distribution is per-book isolated: each book keeps its own `RARExtractor.ExtractionSelection`, and a book that fails to extract is logged and skipped without failing the others or the owning task.
- The persisted queue lives under one `UserDefaults` key owned by `UnifiedDownloadQueueStore`. Completed and cancelled tasks older than `finishedTaskRetention` are dropped when the queue is restored; unfinished tasks are restored as-is. Nothing reconciles a restored task against a live `URLSession` transfer, so an unfinished task can come back stale.
- Provider-specific download behavior belongs in a `DownloadPlanProviding` implementation, not in the scheduler.
