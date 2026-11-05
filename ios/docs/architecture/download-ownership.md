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
| Profile-scoped background HTTP audio transfers, local file copy, and SMB | `BookDownloadManager` |
| HTTP attempt/part identity, durable completion/failure, restart recovery | `BookHTTPTransferStore` |
| Whole-book staging and atomic publication | `AtomicDownloadDirectory` |

## Rules

- Only `LocalStorageManager` defines where audiobook files live. `DownloadDestinationFileSystem` is constructed with that root and sanitizes book identifiers through `LocalStorageManager.sanitizedId`. The root is injected rather than read from the singleton because the background `URLSession` delegate resolves destinations off the main actor.
- Downloaded audio is written as `chapter_<index>.<ext>` inside the book directory. `UnifiedDownloadService` and `DownloadArchiveFileSystem.extractZip` go through `DownloadDestinationFileSystem.chapterFile`. `BookDownloadManager`, `RARExtractor`, `StorytellerReadaloudOfflinePrep`, and `LocalStorageManager` still compose that name themselves, so the layout is a shared convention rather than a single enforced producer.
- HTTP audio is staged under `.enve-download-<attempt UUID>` and published only after every part succeeds. `AtomicDownloadDirectory` swaps whole directories, preserving an existing complete copy on failure. A hidden attempt marker travels with publication so restart recovery cannot swap the old copy back. Other file replacements use `DownloadDestinationFileSystem.replaceItem`.
- `DownloadArchiveFileSystem.extractZip` stages into an `archive-staging` subdirectory of the destination and removes it, plus the archive, before returning. Real-Debrid multi-book distribution uses `stageForDistribution` to move the archive out of the audiobook tree while each book's destination is cleared. Neither staging area survives a normal return, both can survive process termination, and nothing sweeps a leaked staging directory on relaunch.
- Multi-book distribution is per-book isolated: each book keeps its own `RARExtractor.ExtractionSelection`, and a book that fails to extract is logged and skipped without failing the others or the owning task.
- The persisted queue lives under one `UserDefaults` key owned by `UnifiedDownloadQueueStore`. Completed and cancelled tasks older than `finishedTaskRetention` are dropped on load. `UnifiedDownloadService` reconciles restored active entries with both its legacy background session and `BookDownloadManager` before treating them as interrupted.
- Audiobookshelf single/multi-file audio, provider HTTP audio, and remote multi-file audio use `BookDownloadManager`'s `com.enve.book-http.<profileID>` background session. Every part receives an attempt-scoped `taskDescription`; its manifest is written before native tasks resume. Manifests contain identities and relative filenames, never request URLs, credentials, or resume blobs. Only current incomplete parts accept callbacks, and cancellation revokes their ownership before cancelling native tasks.
- An Audiobookshelf audiobook with no stored full file list resolves its expanded library item before scheduling, even when a primary file ID is present. A podcast episode keeps its own file ID rather than downloading the parent item's files.
- Restoration inventories native tasks, resumes owned suspended tasks, retains partial staging for live attempts, and records an interruption when a required transfer is gone. Startup cleanup preserves staging named by the manifest. Completed results remain durable until offline metadata and queue completion are recorded. These writes finish before the matching OS background-events completion handler is called; optional cover fetching and media probing happen afterward.
- Both background session identifiers route through `CarPlayAppDelegate` and `ProfileSwitchCoordinator` to their original profile. HTTP staging, audio, and transfer manifests use file protection that permits access after the device has first been unlocked. Ordinary screen lock is supported; user force-quit is a separate OS cancellation case. SMB, local copies, and the custom Real-Debrid HTTP/1.1 transport do not gain OS-owned background transfers from this mechanism.
- Provider-specific download behavior belongs in a `DownloadPlanProviding` implementation, not in the scheduler.
