# Profiles implementation plan

Status: implementation in progress on iOS and Android, October 6, 2026. Catalog, PIN, captured runtime graphs, profile switching, personal preferences, history, offline storage, and completed-media import are implemented. Release verification is in progress; physical-device coverage remains required.

Initial foundation verification: iOS AllTests passed 1,182 tests with 10 skipped on iPhone Air; reader position tests emitted audio-session runtime warnings. Android core and app unit tests, debug test build, minified release build, and all five profile persistence tests on Pixel 7a passed. These initial checks cover the catalog and PIN foundations. The dated foundation and prototype results below are historical checkpoints, not release verification of the current runtime.

Profiles let people share a device while keeping separate server logins, libraries, reading positions, and listening history. Downloaded media can be explicitly shared between profiles without downloading or copying it again. The feature is optional and off by default. Existing installations keep their current experience until Profiles is enabled.

The request comes from [eaglescreech’s readaloud feedback](https://discord.com/channels/1481752416247615642/1503166047501549619/1557010981069262880) and [erictb’s suggestion of separate logins and an adult PIN](https://discord.com/channels/1481752416247615642/1503166047501549619/1557074822574510111).

This contract is kept at docs/architecture/profiles-plan.md in both app repositories. Update both copies when a shared decision changes.

## Current runtime verification — October 6, 2026

- iOS: AllTests on iPhone Air Simulator passed 1,247 tests, with 10 skipped and zero failures (1,257 total). Existing audio-session runtime warnings remain. The profile UI workflow passed setup with sync enabled, changing sync to off, switching, relaunch, empty destination library, returning to the owner, removal, and disabling Profiles. A WebKit identifier-removal crash found during simulator testing is avoided by clearing the captured profile website data instead.
- iOS: signed physical-device build-for-testing and the watchOS Simulator build passed with zero new compiler warnings. The physical iPhone remains unavailable to Xcode, so physical iPhone behavior has not been verified.
- Android: core/engine/app unit suites ran 837 tests: 836 passed, one skipped and zero failures. Debug, test APK and minified release builds passed with zero new warnings. Final Pixel instrumentation reported OK (147 tests), including profile media import, sync preferences, screen-disposal switch lifetime and all eight Android Auto tests. Manual Pixel setup verified default sync off, opting in before save, changing to off, switching, relaunch, an empty destination library, returning to the owner, removal and disabling Profiles. Switching now completes in the application scope after the initiating screen is disposed. A cold launch reported zero fatal or Compose errors; Tailscale was running on the Pixel. Remaining hands-on checks are listed in the desktop sticky note “Enve Book Player — remaining hands-on checks”.
- Both provenance checks pass. Release acceptance still requires the remaining device and real-server scenarios below; these results do not certify every provider or companion surface.

## Settings and reader experience

Settings gains a Profiles entry. Before setup it explains: “Share this device with separate libraries and reading progress.” Setup names the current owner profile, asks whether children will use the device, and requires a parent PIN before creating a child profile.

Enabling Profiles assigns all existing data to the owner profile. Adding another adult or child creates an empty profile. Each profile receives only connections explicitly added for it, with separate credentials; no adult connection, imported book, download access, or reading history is inherited automatically. Setup offers an optional “Import downloaded books” step; it is also available later in Settings → Profiles → [profile] → Import downloaded books.

Each added profile asks “Do you want to turn on syncing?” directly below its name. Server syncing defaults to off for added adult and child profiles. Turn it on to continue reading and listening across devices using that person’s server account; leave it off when sharing a login to keep personal progress separate. An authorized adult can change the choice later in Profiles. Catalog browsing, authentication and downloads work while personal progress syncing is off. Remote resume positions, completion, reading/listening history and pending uploads are gated by the captured profile preference. Activity recorded while syncing is off stays local and is excluded from history replay after enabling. The existing owner keeps its previous sync behavior.

The Profiles page shows names, adult or child labels, and the current profile. The owner can add, rename, remove, and switch profiles. A profile selector is also available from Home so switching does not require finding a settings submenu. A profile needs only a display name and an optional built-in avatar; no email address or birth date is collected by Enve.

| Action | Adult profile | Child profile |
| --- | --- | --- |
| Browse, read, listen, download | Own library | Own library |
| Personal reading and accessibility preferences | Available | Available |
| Add or edit server connections | Available after parent authorization when children exist | Parent authorization required |
| Manage profiles, PIN, exports, or app data | Owner or authorized adult | Parent authorization required |
| Switch to a child | No PIN | No PIN |
| Enter any adult profile when children exist | Parent PIN | Parent PIN |
| Switch between adult profiles without children | No PIN by default | Not applicable |

Adult profiles share a household administration gate in the first version. The PIN does not provide separate private vaults for multiple adults.

Child mode keeps the normal reader and player and simplifies administration. It does not infer age suitability from titles, genres, or incomplete metadata. Parents control available books through the child’s server account permissions and the sources added to that profile. A locally imported book is initially available only to the profile that imported it. An authorized adult can grant another profile access through Import downloaded books.

The selected profile survives app restart. Restarting while a child profile is selected must never briefly display adult content. “Ask who is reading on launch” can be an optional preference after basic switching works. Disabling Profiles requires parent authorization and removal of extra profiles; no profile data is merged into the owner automatically.

## Data ownership

A profile ID is a durable local identifier, independent of display name, server username, or book ID. Existing content IDs keep their current meaning; profile ownership is a separate local dimension.

| Ownership | Data |
| --- | --- |
| Device | Profile list, selected profile, parent PIN verifier and lockout state, system permissions, hardware and e-ink detection, total storage accounting |
| Reused media | Completed, explicitly imported audiobook, ebook, comic and PDF payloads; catalog-authorized media references or filesystem clones reuse storage; each profile owns its manifest, artwork, import receipt and local library record |
| Profile | Connections and credential references; library and cover caches; download access and queue ownership; private imported files; reading/listening positions; bookmarks and annotations; history and upload receipts; collections and saved books; companion links and confirmed matches; podcast subscriptions; player queue and resume state; reading goals and statistics |
| Profile preferences | Theme, Home shelves, library filters and sort, playback defaults, reader typography, accessibility choices, sync destinations and opt-ins |

New profiles start with system appearance and safe reading defaults. Hardware accessibility capabilities remain device owned; a person’s chosen display and reader preferences belong to their profile.

Storage direction: separate local database, preference namespace, and private file root for each profile, using the existing domain stores behind an immutable profile storage context. Imported media resolves through destination-owned paths and private import receipts; personal state never lives in shared media sidecars. The storage prototype confirms independent databases with overlapping content identities. Adopt existing paths as owner resources; do not relocate live owner files. Any store that cannot be partitioned must carry explicit profile ownership in every read, write, queue entry, and uniqueness constraint.

Do not change provider book IDs, stable IDs, or provider payloads to encode a local profile. Within a profile, offline files must also distinguish connections and media formats. An imported item receives a new destination-local ID, independent of the source server book ID. Two accounts returning book ID “42”, or an ebook and audiobook attached to one server item, must not overwrite each other.

A background operation captures its profile and connection when created. It must never obtain its destination from whichever profile happens to be selected when a response arrives. This applies to network responses, downloads, WorkManager or URLSession jobs, progress pushes, listening history, and cover requests.

Cloud and companion features must also respect ownership. Until a feature has profile-aware routing, child profiles cannot use it. In particular, existing owner CloudKit records, shared iCloud files, watch resume data, widgets, Spotlight or search indexing, and car playback must not publish adult content while a child is active. Existing owner sync remains available in the owner profile. Cross-device discovery and synchronization of the profile list are outside the first release; each person may still sync reading progress through their own server account.

## Import downloaded books

This is an explicit local access grant. The picker lists completed downloads with title, artwork, available formats and size. It supports selecting individual books and formats, plus Select all. It never lists another profile’s books before the adult administration gate is satisfied when children exist. Only an authorized adult can change a child’s grants.

Import reuses the existing media bytes and required offline metadata/artwork. It creates a destination library record and private media references, with fresh reading/listening positions and no copied bookmarks, annotations, history, collections, credentials or server session. The destination can read or listen offline without adding the source server account. Its local item does not send progress to the source profile’s account. Remote sync requires a separately configured destination account and an explicit, verified match through the normal matching flow.

Keep audiobook and ebook assets separate even when they belong to the same book. A paired readaloud import grants both available formats and creates a destination-owned pairing; each reader’s progress remains private. Mutable playback, readaloud and reader sidecars remain in that profile’s stores. Destination media paths must not expose the original profile’s private directories or credential-bearing manifests.

Preserve existing owner paths. Android adopts completed payloads into device-owned shared storage and persists explicit profile access references. Adoption records must be durable before moving the original file, with recovery restoring its private path after interruption. Only catalog-authorized private links may resolve shared media. Every replacement writer must unlink the old final reference before publishing a new file and must fail if unlinking fails. Pixel testing confirmed hard links are blocked by Android security policy; do not use them. iOS clones payloads with copy-on-write filesystem semantics so existing writers cannot mutate another profile’s media. Neither operation falls back to copying the media bytes; unsupported reuse reports an error. Mutable manifests, covers, receipts and reader sidecars remain separate. Quiesce source operations and validate completion before import. Validate the files before committing the grant; importing an incomplete or missing download reports the problem without claiming offline availability. Persist the destination item and media references with a recoverable operation so interruption and repeated imports are idempotent. Do not identify assets by title or server book ID alone, and do not merge unrelated accounts’ downloads automatically.

“Remove download” removes that profile’s grant. The source profile does not have special permission to delete bytes still granted to someone else. Profile deletion, Clear downloads, storage cleanup and repair remove only the selected profile’s references. Android retains adopted blobs until catalog grants and active readers permit reclamation; iOS filesystem clones have independent lifetimes. Replacements must preserve media still used by another profile or an open reader/player. Count shared bytes once in device storage and label them as shared in profile storage details. Missing media is reported to every affected profile without silently switching accounts or starting a source-account download.

This shared-media flow is required for the first profile release. The existing isolated storage constructors remain valid for private data. Import storage APIs are being implemented; library insertion, captured queue ownership, storage accounting and the picker still require integration.

## Safe switching

1. Authenticate entry into an adult profile when required. Keep the old profile selected if verification fails.
2. Prevent new playback, reader, download, and source actions while switching.
3. Save the current reading position and measured listening session locally. Close readaloud and reader engines, stop playback, and clear media controls and artwork. Network availability must not block saving or switching.
4. Cancel foreground profile work and pause downloads owned by the outgoing profile. Persist pending work under that profile; already dispatched work may complete only in its original scope.
5. Close or detach outgoing stores and clear navigation, search, image memory caches, queues, and observable UI state. Reject late UI updates from the old session.
6. Open the destination profile’s stores, connections, preferences, and library. Commit the selected profile only after loading succeeds, then show Home. Do not autoplay.
7. Refresh widgets and companion surfaces using the selected profile’s allowed data. Resume background retries only according to their original ownership and the active profile policy.

Switching is serialized. A failed destination load returns to the previous usable profile without mixed content. Relaunch after termination during a switch restores one fully committed profile.

The first release pauses inactive-profile downloads and sync retries. An already sent server request cannot be recalled, but its response and local receipt stay bound to the outgoing profile and account.

## Migration and removal

Existing connections, their IDs, credentials, imported files, downloads, annotations, progress, history, collections, and queued work become the default owner’s data. Preserve content identities and existing server mappings.

Before relocation, quiesce writers and checkpoint databases. Validate the destination and record migration completion before retiring old files. Handle process termination, low storage, and a retry without duplicating or losing user data. Never use a destructive database fallback.

Where a legacy record lacks sufficient connection identity to resolve a collision, preserve it in the owner profile and flag the ambiguous association for repair. Do not silently attach it to another account.

Removing a profile requires parent authorization, stops its sessions and jobs, and removes only that profile’s local stores, cached files, credential references, and indexes. Explain that this removes the profile’s download access and unsynced progress but does not delete the server account or remote books. Remove only that profile’s media references; shared storage ownership preserves payloads still used by another profile or an active reader/player. The owner profile cannot be removed through this flow. Deleting the active profile first returns to an authenticated owner session.

## PIN behavior

Require PIN confirmation during setup and change. Use the existing salted verifier foundations, secure platform storage, and persisted attempt limits. Never store or log the entered PIN. Parent authorization is short lived and is revoked on backgrounding, profile switching, and app restart.

PIN recovery uses device owner authentication before replacing the verifier. If device authentication is unavailable, explain the recovery requirement during setup and prevent enabling child protection until a supported recovery path is configured. Do not offer an unauthenticated reset that exposes existing adult data.

The PIN protects Enve’s adult navigation and administration. Server authorization remains the responsibility of each account’s permissions.

## Platform ownership

| Area | iOS | Android |
| --- | --- | --- |
| Profile metadata and PIN | Services/Profiles; existing AdultPINStore and AdultPINCredential | core/data/local; existing FamilyProfileStore, FamilyProfile, AdultPin |
| Switching orchestration | Focused service composed at the App layer; main actor UI updates | engine service reached through an engine-api ProfilesFacade |
| Settings and selector | Screens/Settings and Home composition using Hearth | hearth-ui/profiles and settings using Hearth; no concrete backend imports |
| Connections | ProviderConnectionStore and credential references | ConnectionRegistry and scoped credentials |
| Databases | BookStoreManager, SwiftData repositories, remaining domain stores | ReaderDatabase/Room, BookCacheDao, remaining domain stores |
| Files and jobs | Download ownership and URLSession queues; local imports; completed-media import | OfflineAudioStorage, shared media catalog, download manager and WorkManager queues; local imports; completed-media import |
| Playback and readers | Existing playback composition, session services, reader lifecycle | PlayerSessionService, Media3 service, Readium and reader Activities |
| External surfaces | CloudKit, app group, widgets, Watch, CarPlay, Spotlight | Widgets, Wear, Android Auto, shortcuts, automation and notifications |

Keep corresponding concepts named consistently: FamilyProfile, FamilyProfileRole, FamilyProfileStore, and ProfileSwitchCoordinator. Adapt platform concurrency and lifecycle mechanisms without building a generic cross-platform framework.

Both platforms now have profile catalog storage for adults and children, name validation, and PIN verification. iOS also has a verified PIN change operation; Android retains its existing verified PIN replacement. Catalog reload preserves additional adults, and malformed catalogs fail instead of silently restoring the owner profile. This describes the initial foundation checkpoint; the captured runtime and switching UI have since been implemented and are undergoing verification.

Implementation reaches protected storage boundaries. Android PreferencesManager.kt and iOS SharedKeychainStore.swift are marked agent locked. Follow each repository’s AGENTS.md before inspecting or editing them. More credential files may require the same process after the integration audit. Planning and unprotected work can proceed independently.

## Storage audit findings

The first audit found these concrete integration points. They must be scoped before the profile picker is exposed.

| Domain | iOS integration points | Android integration points | Required change |
| --- | --- | --- | --- |
| Preferences and connections | ProviderConnectionStore, SettingsManager, LibraryDisplayPreferencesStore, reader appearance stores | EnveDataStore, PreferencesManager, ConnectionRegistry, HearthPreferencesStore | Separate personal defaults and the connection list; device profile metadata remains outside these namespaces |
| Main database | BookStoreManager uses Documents/BookStore.sqlite | ReaderDatabase holds a process-wide instance of reader.db | Open a profile-owned database and detach the outgoing repositories and observers before activation |
| Player database and state | PlaybackStateManager creates a second persistent ModelContainer; PlayerStateStore and PlaybackQueueStore also persist state | PlayerBookmarkService writes audiobook-bookmarks by book ID; playback queue is in Room | Partition all player stores, not only the library database; stop the old session and clear media controls |
| Offline files | LocalStorageManager, download destinations, local ebook import and remote import paths | OfflineAudioStorage and ComicOfflineStorage use device file roots; audio pending requests use only book ID | Private roots plus connection and format identity; private media references for explicit reuse; separate mutable sidecars; keep old relative paths valid during owner migration |
| History and retries | HistorySessionModels, ABSLocalListeningStore, ProviderHistorySessionSync, CrossProviderHistorySessionSync | HistorySessionStore, AbsLocalListeningStore, AbsCrossProviderHistorySync, PendingProgressPushDao, BookOrbitHistorySessionSync | Capture profile/account ownership in jobs and receipts; reload only the active profile’s history |
| Collections and matching | StorageService, work/series overrides, matching queue, podcast subscriptions | CollectionsFacadeImpl, saved books, DuplicateGroupStore, matching review and podcast subscriptions | Scope stored rows, JSON/preferences, custom covers and subscription state |
| Caches and generated content | AppCache, DiskImageCache, catalog checkpoints, StoryAlign and intelligence stores | Provider book-index caches, GrimmoryDiskCache, comic pages, EPUB search, StoryAlign and librarian stores | Partition content-bearing caches and outputs; clear outgoing in-memory state; explicitly classify shared model binaries |
| External and destructive actions | WidgetSharedState, Watch/CarPlay, CloudKit, Spotlight, MaintenanceEngine and StorageScreen | Widget publisher/store, Wear, Android Auto, automation, notifications and StorageHubViewModel | Route external requests to an allowed profile and constrain cleanup/export to its files |

Credential references must be checked through the protected stores rather than inferred from unprotected callers. The current iOS connection store also reads legacy backends from ServerConfigStore; legacy fallback must not repopulate a new child’s empty profile. The Android connection registry and general preferences share the enve_prefs DataStore, while Hearth has a second hearth_prefs store; both need the same profile ownership policy.

Existing owner storage locations remain unchanged. At this historical checkpoint the live app still selected the owner. The current implementation replaces the active service graph during serialized profile switching.


## Historical storage prototype — October 6, 2026

- Both apps have immutable `ProfileStorageLocations`. The owner adopts legacy directories and database names; other identities receive separate roots. Catalog loading rejects duplicate or unsafe identities before paths are constructed.
- iOS opens independent library and playback containers through throwing constructors. New profile activation never invokes the owner's destructive recovery path or legacy library import. Owner `.shared` startup behavior is preserved.
- Android explicitly opens Room databases with the existing migration chain and no destructive fallback. Its existing owner singleton remains the production default.
- Android connection and Hearth preference stores capture their DataStore at construction. Owner instances reuse the existing DataStores; new profile resources own separate files and coroutine lifetimes. Do not create two concurrent resources for the same profile preference files.
- iOS connection Keychain storage supports a profile namespace. Owner service, access group, and synchronization behavior are preserved; new profile credentials are device-local. Connection Codable captures its supplied Keychain through encoder/decoder userInfo. Scoped connection stores capture defaults, reject legacy backend imports for nonowners, and skip CloudKit pushes. Provider-specific credential operations and active-session account resolution still require integration.
- Android credential vaults use separate encrypted preference files per profile while preserving the owner's legacy filename. PreferencesManager captures its DataStore, vault, and coroutine scope; profile logout cannot clear another profile's login.
- Both platforms capture listening-history files. New profile activation rejects unreadable or corrupt history, preserving its bytes and owner data; owner startup compatibility remains unchanged. Delayed outgoing writes stay in their captured store.
- Audio/comic storage on Android and audiobook storage on iOS capture profile roots. Actual file, cover, manifest, sidecar, progress, pending-request, reopening, and deletion tests prove independence for identical media identities. iOS download-ID caches are instance-owned and legacy Documents fallback is owner-only. Android manifest paths reject escapes from their captured root.
- iOS profile defaults have a stable namespace; library-display and player-preference stores accept captured defaults. These constructors and the other resource owners still need consistent session composition.
- Tests prove explicit storage handles, not isolation of the entire running app or background download pipeline.
- iOS AllTests: 1,202 passed, 10 skipped, zero failures on iPhone Air. Existing audio-session runtime warnings remain in reader-position tests; no new compiler warnings. Android: all 27 focused profile integration tests passed on Pixel 7a; core/engine/app unit suites ran 835 tests with one skipped and zero failures. Debug and minified release builds passed with no new warnings. Both provenance checks passed.

## Historical completed-media import prototype — October 6, 2026

- Android `OfflineAudioStorage` and `ComicOfflineStorage` import completed media through `CompletedDownloadImporter`. A device-owned catalog adopts payload bytes once, keeps original paths usable through private links, and grants each destination its own local identity, manifest and receipt. Resolution accepts only catalog-authorized paths; removal revokes only that profile’s references.
- Pixel testing rejected the initial hard-link approach through Android security policy. The replacement shared-storage approach passed on the physical device. Asset journals are persisted before moving files, and opening storage repairs adoption interrupted before or after the move. Failed imports preserve source access and do not publish a destination item.
- Android final-file replacement fails if the old entry cannot be removed; fallback publication cannot overwrite a raced destination. Unreferenced blobs and interrupted staging artifacts are retained for now. Reclamation and accurate shared-storage accounting are required before exposing the feature.
- iOS `ProfileDownloadImportService` imports completed audiobook, EPUB, comic and PDF payloads using filesystem clones without a media-copy fallback. Destination files have independent inodes and survive source mutation or deletion. Private metadata, artwork and receipts publish together. Repeat imports preserve the imported identity, including after source media is removed.
- iOS `LocalEbookImporter` captures profile roots for ebooks, readaloud, reader caches and conversions. Nonowner stored paths cannot resolve another profile’s files or symlink escapes; cleanup stays within the captured profile. Existing owner paths remain compatible.
- Imports create fresh local metadata without remote account routing, signed URLs, source progress, bookmarks or history. Destination library insertion must be insert-if-absent so repeating an import cannot reset that person’s saved progress. Android artwork import and readaloud pairing integration remain to be completed.
- Callers must obtain completion proof from the captured source download owner and quiesce writers. The current storage APIs do not yet replace the live owner service graph, insert library records, authorize the import picker, or expose switching UI.
- Verification: iOS AllTests passed 1,212 tests with 10 skipped and zero failures on iPhone Air, including five import tests and five ebook storage tests. Existing audio-session runtime warnings remain; no new compiler warnings. Android passed all 38 profile/import integration tests on Pixel 7a, including 11 import/recovery tests. Core/engine/app unit suites ran 835 tests with one skipped and zero failures. Debug and minified release builds passed with no new warnings. Both apps were installed and launched successfully; both provenance checks passed.

### Required lifecycle integration

Android's Hilt singleton graph retains concrete DAOs, preference flows, file roots, and cached queues. Changing a database filename or refreshing the navigation tree cannot detach those references. Profile-sensitive operations must capture their concrete resources before suspension; active UI observers must move to the new session. Keep outgoing resources alive until admitted work finishes or cancellation joins. Avoid dynamic DAO proxies, process restarts, and global path getters that resolve late.

iOS AppState, provider sync strategies, catalog/progress stores, and reader/player history currently retain shared owners. Activation must recompose those owners and cancel or join startup/refresh tasks. Download task metadata and callback routing must carry profile, connection, and media-format ownership across relaunch. Local session checkpointing must complete before selection changes and must not wait for a network upload.

Legacy account fallbacks, credential decoding, history queues, custom covers, imports, deletion, sync receipts, and companion surfaces must be scoped before exposing Settings or Home switching. Release acceptance requires these gates to pass.

## Implementation sequence and acceptance gates

1. **Storage and lifecycle audit.** Inventory every persistent store, singleton, pending operation, and external surface. Record device or profile ownership and its migration path. Prototype two profile storage contexts on both platforms. Gate: identical server book IDs remain distinct; explicit imports reuse media bytes with separate personal state; current owner data survives migration.
2. **Backend switching.** Implement profile activation, safe session shutdown, scoped stores, captured job ownership, PIN checks, and recovery. Keep the picker unexposed. Gate: switch during playback/readaloud and pending network work without mixed state; relaunch and offline switching work.
3. **Settings and Home UI.** Enable setup, add an adult or child, import selected existing downloads, rename, remove, switch, change PIN, and reset through device authentication. Match behavior on iOS and Android; use platform-native presentation. Gate: settings flow works with VoiceOver/TalkBack, large text, dark/light themes, and Android e-ink.
4. **Companion and sync coverage.** Complete ownership for widgets, watch, car, cloud sync, exports, search and automation, or block unsupported child routes. Gate: no inactive adult book, artwork, progress, or controls appears externally.
5. **Release verification.** Run migration, isolation, PIN and failure tests; build both apps; exercise real accounts and offline content. Gate: all scenarios below pass before the optional feature becomes visible.

Implement each slice on both platforms before moving to the next. iOS remains compatible with iOS/iPadOS 17; Android retains its current supported minimum. No new service account system or subscription is needed.

## Required verification

- Upgrade an existing installation with books, annotations, paired readaloud, downloads, collections and pending progress; everything belongs to the owner and remains usable.
- Add two logins to the same server with overlapping book IDs; positions, bookmarks, history and private downloads remain independent.
- Import selected completed downloads into an adult and a child profile without copying bytes or using the network; each starts fresh and saves independent positions, bookmarks, annotations and history across switching and relaunch.
- Import audiobook and ebook formats individually and together, including readaloud; verify neither format overwrites the other and no source credentials or sync account is inherited.
- Repeat an import, interrupt it, and retry; no duplicate library item, media reference or media copy is created. Missing or partial files cannot be imported as completed downloads.
- Remove a download from its original profile, remove another profile, and run storage cleanup while a shared book is open; remaining profiles retain usable media. Storage totals count each physical asset once.
- While a child is active, attempt to browse the import picker without authorization; adult titles, artwork and metadata remain hidden.
- Add an additional adult and a child; rename either without changing identity or losing data.
- Switch while playing audio, reading an ebook/comic/PDF, using readaloud, seeking, and starting a download.
- Switch while network responses, progress uploads and listening-history retries are in flight; late results cannot reach the new profile.
- Switch and relaunch entirely offline; airplane mode permits only the selected profile’s private downloads and explicitly granted shared media.
- Terminate the app during migration and switching; recover without adult content appearing in a child profile.
- Exhaust PIN attempts, relaunch during lockout, change PIN, reset through device authentication, and background during parent authorization.
- Open deep links, system media controls, notifications, search results, exports, widgets, car surfaces and watch requests while a child is active.
- Delete a profile with pending work; verify another profile’s files, credentials and remote data survive.
- Verify cross-provider history mapping and sync receipts remain tied to the original profile, source account and destination account.
- Validate small screens, large text, screen readers, reduced motion and e-ink.
- Run required unit/integration tests, debug and release builds, iPhone/iPad simulator workflows, and physical Pixel workflows. Record exact results; code review and compilation alone do not establish isolation.
