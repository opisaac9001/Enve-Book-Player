# Enve UI Design

*This document describes the Enve book player's experience layer.
The machine underneath — providers, sync, playback, reader engine, book store — is unchanged.
Everything the user sees and touches is new.*

---

## The idea

The old Enve is a **media manager**: five tabs, dense grids, badges, hubs, admin panels.
Tremendous power, presented as a control room.

The reimagining is a **reading room at night**.

A book on the hearth, glowing. Stacks of books in warm shadow behind you. A journal on the
side table recording the nights you've spent here. The app should feel the way reading feels:
quiet, warm, focused — one thing lit at a time.

Three principles guide the design:

1. **One continuum.** An audiobook and an ebook are the same story at the same position.
   The app's superpower (cross-format sync, read-along, linking) becomes the *organizing idea*
   instead of a buried feature. One "continue" shelf, one progress model, one player surface.
   Never two glued apps.
2. **Chapters are the unit of thought.** Chapter title in the mini player, chapter-segmented
   scrubber, "time left in chapter", end-of-chapter sleep timer. People don't think in
   percentages.
3. **Opinionated calm over settings sprawl.** Strong defaults, few toggles, no hubs.
   Power features that survive do so by being invisible until summoned.

## Design language: **Hearth**

Named for the home screen and the brand ember. Swift namespace: `Hearth`.

### Color

Token-based; two palettes plus System-follow. OLED-friendly dark is the soul of the app.

| Token | Ink (dark, default) | Paper (light) |
|---|---|---|
| `bg` | `#0C0A09` warm near-black | `#F7F2E9` warm paper |
| `bgElevated` | `#191512` | `#FFFFFF` |
| `bgSunken` | `#000000` (player/reader) | `#EFE8DB` |
| `text` | `#F0E9DC` warm ivory | `#231F1B` ink |
| `textSecondary` | `#A99F92` | `#7A7064` |
| `textTertiary` | `#6E665C` | `#A89D8F` |
| `ember` (accent) | `#F5921A` | accent deepened ~9% brightness for contrast |
| `emberSoft` | ember @ 14% | ember @ 12% |
| `hairline` | white @ 8% | black @ 8% |
| `onEmber` | `#1A120A` ink (both modes — contrast on ember/ambient fills) | same |
| `statusOK/Warn/Error` | warm-tuned sage/amber/terracotta | deepened equivalents |

- **Ember `#F5921A` is brand continuity** — same hex as the old accent and the AccentColor asset.
  Honor the user's custom accent: read `themeColorHex` from UserDefaults (same key the old
  ThemeManager used) as an override; default to ember.
- **Per-book ambient tint**: a small utility extracts a dominant color from the cover
  (downsample + average, cached by stableId). Used for the player glow, detail header wash,
  and the now-playing pill ring. Falls back to ember.
- Old `ThemeManager` + `Utilities/Theme.swift` stay compiled (engine references) but the new
  UI reads only `Hearth` tokens. `Hearth.mode` (system/ink/paper) persists to its own key.

### Type

- **Serif display (New York via `.fontDesign(.serif)`)** for book titles, screen titles,
  chapter names, big numbers. This is the single loudest move away from the old app.
- **SF** for UI labels, body, controls.
- **Overlines**: 11pt semibold, small caps feel via `.tracking(1.6)`, uppercase, textSecondary —
  used for section headers (`EMBERS`, `CHAPTER SEVEN`, `THIS WEEK`).
- The whole ramp scales: `Hearth.scaled()` applies Dynamic Type (UIFontMetrics) plus a 1.15×
  factor when the engine's vision-impaired toggle (`ThemeManager.shared.isVisionMode`) is on.
  All type goes through `.hearthDisplay()` / `.hearthUI()` — never raw `.system(size:)`.

### Texture & motion

- `EmberGlow`: a slow radial glow (book-tinted) that **breathes when audio is playing**
  (≈7s ease cycle, ±6% radius) and holds still when paused. Player background; subtle echo
  behind the Hearth hero. Honors Reduce Motion (static gradient).
- Surfaces are flat warm darks with hairline strokes — **no ultraThinMaterial anywhere**.
  Material blur was the old app's texture; the new one is ink and light.
- Covers get `12pt` radius, 1px hairline, and a soft tinted shadow (`ambient @ 25%, y:8, blur:24`).
- Progress is drawn as a **ribbon**: a thin (3pt) rounded bar with chapter tick marks, filled
  in ember/ambient. Used on cards, detail, reader footer. The player gets the full
  **chapter ribbon** (see Player).
- Haptics through the existing `PlatformHaptics` helper. Springs: `.snappy` for chrome,
  `.smooth(duration: 0.35)` for sheets/morphs.

## Information architecture

```
MantelBar (floating dock, the only chrome)
├── Hearth    — now. current book hero, continue shelf, recently added
├── Library   — everything. search, filters, facets, 50k-ready grid
└── Journal   — your reading life. week numbers, streak, heatmap, finished shelf
                + entry to Sources & Settings (gear also on Hearth header)

Now-playing pill — docks INTO the MantelBar when a book is loaded; expands to Player
Player  — full-screen cover + chapter ribbon (fullScreenCover)
Reader  — full-screen ebook chrome over ClassicReaderModel (fullScreenCover)
Detail  — book page (push within tab or sheet)
Sources — connected services + add flows (push from settings)
```

**The MantelBar** replaces the 5-tab bar + separate mini player. One floating rounded bar,
bottom-docked with safe-area padding:

- Idle: three glyph+label tabs (Hearth flame, Library books, Journal pen).
- Book loaded: the left ~45% becomes the **ember pill** — tiny cover with an ambient progress
  ring, marquee title · chapter, play/pause. Tabs compress to glyphs on the right.
  Tap pill → Player. The pill is the mini player; there is no second bar.
- Exposes its height via a `mantelInset` environment value (replaces `bottomBarInsetHeight`);
  scrollable screens pad by it.

## Screens

### 1 · Hearth (home)

- Header: overline greeting (`TUESDAY EVENING`), serif `Hearth` title, gear → Settings.
- **Hero — the current book** (`AppState.currentBook` ?? most recent of
  `continueListeningBooks(limit:1)` / `continueReadingBooks(limit:1)`): large cover left,
  right column = overline (`CHAPTER 7 OF 23` or `PAGE 142`), serif title (3 lines max),
  author, ribbon progress, `2h 14m left` , and a big ember **Continue** button
  (`EnveEngine.shared.playback.play(book)`). Behind it: faint `EmberGlow` in the book's ambient color.
- **Embers** — horizontal shelf merging `continueListeningBooks(limit:12)` +
  `continueReadingBooks(limit:12)` (dedup by stableId, sort by lastUpdate, drop the hero).
  Card = cover + ribbon + time-left caption. Audio/ebook distinguished only by a tiny glyph.
- **Fresh ink** — `recentBooks(limit:12)` horizontal shelf, plain covers.
- Empty state (no connections): a warm full-screen invitation — ember glow, serif
  "Light the fire." copy, one button → Add a source.
- Pull-to-refresh → `SyncCoordinator.shared.manualSync()`.
- Data via `bookStore.observe(...)` streams; no LibraryViewModel.

### 2 · Library

- Large search field (serif placeholder "Find a story…"), debounced →
  `bookStore.searchBooks(query:limit:200)`.
- Chip row: **All · Listening · Reading · Finished · Downloaded** + media-type menu chip
  (Audio / Ebooks / Podcasts) + sort menu (Recent · Title · Author · Series).
- Grid: 3-col adaptive pure covers (no text under covers; title appears on long-press preview
  and in detail). Progress ribbon overlays the cover bottom edge when started.
- **50k path**: keyset paging via `pagedBooks(after:limit:mediaType:)` exactly like the old
  LibraryViewModel (page 2000, paged mode when `bookCount() > 3000`); search always delegates
  to SQLite. Scroll performance is the test gate.
- **Facets**: a segmented overline row — Books · Series · Authors — where Series/Authors use
  `browseSeriesAggregates` / `browseAuthorAggregates` rendered as serif list rows with cover
  thumbs; tapping pushes a filtered grid (`books(bySeries:)` etc.). Series rows show a
  **fanned stack** of up to 3 covers.
- Long-press cover → context menu: Play/Read, Download/Remove download, Mark finished, Hide.

### 3 · Journal

- Overline `THIS WEEK`, two big serif numbers: listening time, reading time
  (from ListeningStatsTracker / ReadingStatsTracker persistence).
- **Streak**: "12 nights running" with a small flame.
- **Year heatmap**: self-sizing ember-tinted grid (GeometryReader column fit). If the stats
  store can't supply per-day history cheaply, ship week numbers + streak first.
- **The Mantel** — finished books as a shelf (`isFinished` query, recent first).
- Quiet footer link → Sources & Settings.

### 4 · Player

Full-screen cover experience over the platform-selected `PlaybackControlling` snapshot (transport) +
`PlayerViewModel.shared` (chapters, sleep, bookmarks) — started through `EnveEngine.shared.playback`.

- Background: `bgSunken` + breathing `EmberGlow` in ambient color + vignette.
- Dismiss chevron top-left; AirPlay (`AVRoutePickerView`) top-right.
- Cover large and still (dignity — the glow moves, not the book).
- Overline chapter label (`CHAPTER 7 · THE LIGHTHOUSE`), serif title, author.
- **Chapter ribbon**: full-width segmented scrubber — every chapter a proportional segment,
  elapsed fill in ambient color, current segment slightly taller. Drag to scrub (global
  seek), with a floating time bubble. Labels: elapsed · chapter-time-left · `-2h 14m at 1.4×`.
  No chapters → plain ribbon.
- Transport row: skip-back / **76pt ember play circle** / skip-fwd (intervals from prefs).
- Utility row (pills): **Speed** (`0.75–2.5×` ruler sheet), **Sleep** (moon; shows remaining;
  sheet = duration grid + *End of chapter* + *End of next chapter* + shake-to-snooze note —
  all existing PlayerViewModel calls), **Chapters** (serif list, current highlighted, tap to
  seek), **Bookmarks** (add at position; list; jump).
- Conflict prompt (local vs server position) and sleep-rewind prompt reuse PlayerViewModel
  state with new styling.

### 5 · Reader

New chrome on the kept engine (`ClassicReaderModel` — relocated, not rewritten; fix the
Readium 3.11 `jsonString()` call sites). All renderers (EPUB/PDF/comic/HTML) flow through it.

- Chrome hidden by default; tap center toggles. Top veil: overline book title, close ✕.
  Bottom veil: ribbon (book position, chapter ticks) + `Page 142 of 380 · 18 min left in
  chapter` + buttons: Contents, Appearance, Search, ⋯ (Narrate/TTS when available).
- **Contents tray**: TOC (serif, indented) / Bookmarks / Highlights tabs.
- **Appearance tray**: theme cards (Paper · Sepia · Ink · E-ink — map to existing
  `ClassicReaderAppearance` themes), font size stepper, font picker (ReaderFontLibrary),
  line-height, margins, paged/scroll toggle. Writes the `appearance` struct; engine persists.
- Selection → floating annotate bar (4 highlight inks, underline, note, Define) — existing
  model calls (`addAnnotationFromSelection`, `vocabEntryFromSelection`, DefineSheet rebuilt thin).
- **Narrate pill** when `hasMediaOverlay` → `toggleReadAloud()`; highlight rendering is
  engine-side already.
- Read-along, Read Together, TTS engines stay wired in the model; chrome surfaces only
  Narrate + TTS in v1 (⋯ menu).

### 6 · Book detail

- Header: blurred-cover ambient wash; sharp cover floating; serif title; author / narrator /
  series links (push to filtered library).
- Status line: ribbon + `Chapter 7 of 23 · 2h 14m left` (or page/percent for ebooks).
- Actions: primary ember button **Listen** / **Read** (`AppState.playBook`); when
  `hasAlternateFormat` / linked: both, side-by-side — the one-continuum moment.
  Secondary: Download (state-aware via `UnifiedDownloadService` + `BookDownloadManager`),
  Mark finished, ⋯ (Hide, sync status).
- Description (expandable serif), About grid (duration, year, genres, source service logo),
  Chapters list (audio), In-series shelf (`books(inSeries:)`).

### 7 · Sources & Settings

Settings as one calm screen, not hubs:

- **Sources** — connected services as cards: provider logo (existing assets), name, URL,
  status dot, book count; re-auth banner when `connectionsNeedingReauth`. Tap → source page
  (rename, credentials/re-auth, library multi-select, archive, delete — same calls as old
  `ServerSettingsView`). **Add a source** → provider grid (logo tiles) → per-provider form.
- **Add flows keep the exact service contracts** (`connections-layer.md` §4, invariants
  verbatim): reuse `ConnectionCapability`, `LoginDelegates`, `BrowserSessionLoginView`,
  MTLS import, Plex PIN polling, OIDC PKCE, Jellyfin QuickConnect, WebDAV presets +
  root-folder picker, SMB, Files/iCloud import, cloud drives. UI rebuilt in Hearth; logic
  untouched. Completion must call `refreshConnectionLibraries` then
  `runRecentlyPlayedSync(trigger: .appLaunch)`.
- **Appearance**: System / Ink / Paper + accent (honors `themeColorHex`).
- **Playback**: skip intervals, default speed.
- **Sync**: CloudKit toggle + status (`SyncCoordinator` observables), Sync Now,
  KOReader (KOSync) connect, Hardcover API-key connect — functional ports of the two
  settings screens, no hubs.
- **Storage**: downloads list (active + completed, pause/cancel), cache clear.
- **About**: version, replay nothing, no Discord sheet, no tutorials.

## Feature parity

The user's directive: the reimagining carries **every feature of the original app** —
reimagined presentation, identical capability. `PARITY.md` is the feature-by-feature map.
Restored domains live in their own folders (Podcasts, Collections, Dedup, Matches,
Hardcover, Discover, Admin, Vocabulary, Librarian) plus depth added to Journal, Sources,
Reader, Player, Library, Book Details, and the app tour. CarPlay unchanged. The only
non-feature: the seasonal-icon engine was already a stub in this variant (toggle kept).

## Build architecture

```
enve/
  App/          App lifecycle, root navigation, MantelBar, and the tour
  Components/   Hearth tokens, EmberGlow, Ribbon, CoverTile, and shared components
  Screens/      Feature folders for Library, Player, Reader, Sources, Settings, and the rest
  Reader/Engine Readium integration and reader state
```

- `enve/App/EnveApp.swift` keeps the existing migrations, plugin bootstrap, app-state startup,
  background tasks, scene-phase hooks, and CarPlay delegate adapter.
  environment = `AppState` + `PlayerViewModel` (+ ThemeManager for engine compat).
- The old `Views/` tree and UI-only view models are removed.
- Swift 6, MainActor-default, `@Observable`, iOS 17 floor (guard 18+ APIs), zero warnings.
- Every UI change is built and exercised on the iPhone Air simulator.
