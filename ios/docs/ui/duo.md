# Enve on iPhone Duo

Build with Xcode 27.1 for Duo support. Hinge and reserved-region calls are guarded by Swift 6.4
compilation checks and iOS availability. Swift 6.3 / Xcode 26.4 CI builds use standard layouts,
and the app's iOS 17 deployment target is unchanged. Xcode 27.1 remains required to qualify Duo poses.

The folding phone is the one device where Enve's "reading room" can be a physical book. This note
describes what the app does in each pose, where the behaviour lives, and how to exercise it without a
device. Every other device keeps the bottom-bar shell unchanged.

## Poses

| Pose | Canvas | Shell | Player | Reader |
| --- | --- | --- | --- | --- |
| Closed (outer display) | 466×678, compact width, side column on the right | **Pocket**: the stacks fill the display; the mantel pill and the tabs stand in the side column below the status bar | Cover with its buttons stacked in the side column | Single page with its buttons stacked in the side column |
| Open flat, held sideways | 951×669, regular × regular, fold inactive, side column | **Spread**: the stacks on the left page, the facing page on the right, the tabs in the side column, a faint spine along the fold | Lives on the facing page; the full-screen cover never opens | Two facing pages with a spine at the fold, buttons in the side column |
| Open flat, upright | 669×951, regular × regular, horizontal bars | Standard shell at regular size (64pt bar) | Stacked cover | Single page |
| Book pose (partly folded, sideways) | fold active, vertical | Spread with the pages inset from the hinge and a deep spine | Facing page | Two pages, deep spine |
| Tabletop (partly folded, upright) | fold active, horizontal | **Nightstand**: the stacks stay on the upright half, the dock with the transport and the tabs lies on the flat half | Nightstand layout with a bedside clock on the upright half | Lectern: page upright, controls flat |

Two rules from Apple's Duo guidance shape all of this. Size classes, not orientation, drive every decision,
and the fold comes from the system rather than from the canvas shape: `GeometryProxy.hearthFold()` wraps
`reservedRegions(kind: .division, options: .includeInactive)` so the fold is known even while the display
lies flat. And on this device the system moves toolbars, tab bars, and navigation controls into a vertical
column on the trailing edge, beside the status bar, on the outer display and on the open display held
sideways; only the open display held upright keeps horizontal bars. `GeometryProxy.hearthSideColumn()`
reads that column as the trailing safe-area inset plus the status bar's occlusion region, so Enve's tabs
and the player's and reader's buttons stand where the system's own bars do and never move when the phone
opens or closes. Split View windows that sit on one side of the hinge report no fold and no column and
stay standard: the nightstand and the lectern need the tabletop pose *and* a horizontal fold through their
own canvas, and they split where that fold actually crosses it (`FoldLine.halves(canvasHeight:)`, which
keeps the hinge's clearance on both sides), never at a presumed halfway line.

## Where it lives

- `enve/Components/HearthFold.swift`: `FoldLine`, the hinge in a view's coordinates (axis, centre, the
  clearance content keeps while folded, and the upper and lower halves a horizontal fold leaves on a
  canvas), and `SideColumn`, the trailing system column with the status bar's extent inside it.
  `topClearance` reserves 24pt above both content panes, subtracting the system's existing top inset.
  The panes use explicit padding because added safe-area padding did not reliably move their controls.
  The stacks are padded from outside; the facing page takes the clearance as `topInset` and pads only
  its content (the player's, the ebook page's, the reading room's, and pushed details), so the shell's
  shared backdrop runs unbroken behind the clearance. The player's geometry reader sits
  inside that padding, so the stacked column's minimum height already excludes the inset and the
  transport stays on screen. Reader overlays use the same clearance; rail controls still measure from
  `statusBarBottom`.
- `enve/Services/System/HingeStateStore.swift`: hinge status and angle from `UIHingeInteraction`;
  `pose(for:)` turns status plus canvas shape into flat, book, or tabletop; `spineDepth(flat:)` deepens
  the spine shadow continuously as the device folds towards a right angle.
- `enve/App/DuoShell.swift`: `DuoShellLayout` (standard, pocket, spread, nightstand), the facing page, the
  nightstand dock, and the spine drawn along the fold. `DuoSpreadBackdrop` is the one surface under an open
  spread: the player's sunken ground, ember glow and foot shade stretched across the stacks, the facing page
  and the rail, tinted by the facing book's ambient colour (the ember with nothing on the mantel) and
  breathing while that book plays. The shell sets `sharesShellBackdrop` on the spread's subtree so every
  `HearthBackground` root on either page (the Hearth, Library, Podcasts and Journal stacks, pushed Settings
  and details) stays clear and the surface runs uninterrupted across the fold; the embedded player and the
  facing page's own views paint no backdrop of their own. A navigation stack also paints its own opaque
  container behind that content, so `clearsNavigationContainerBackground()` applies
  `containerBackground(.clear, for: .navigation)` (iOS 18 and later) at the root of each tab stack and of
  the facing page, including its pushed details. It is constant per device rather than switched on the
  shared flag, so folding never rebuilds a stack. A presentation never inherits the flag:
  `enveEnvironment(session:)` resets it, so sheets and covers keep their own ground. Closed, upright and
  tabletop layouts keep the plain `HearthBackground`.
- `enve/App/AppRootView.swift`: resolves the layout from the fold, the pose, and the size classes, keeps
  the tab stacks in one place in the tree so opening or closing the phone never resets them, and keeps
  the player cover closed while the spread owns the player.
- `enve/App/MantelBar.swift`: the `.rail` placement inside the side column (tabs bottom-aligned like the
  system's tab bar, the pill above them, nothing drawn behind them) and `onMantelBookChange`, which hands the
  mantel book to the facing page and the dock.
- `enve/Screens/Player/PlayerScreen.swift` and `PlayerLayoutPolicy`: `PlayerPresentation` (`cover`, `page`,
  `dock`), the cover's side chrome (close, reading options, queue, AirPlay stacked in the column), the
  nightstand clock, and the dock transport. The full-screen nightstand sizes its upright half, the cover's
  budget, and the flat half from the measured fold; the facing page keeps its own horizontal row, because
  those controls belong to that pane. The stacked column sits in a scroll view with the canvas as its
  minimum height, so it spreads out as before where it fits and scrolls on a short canvas such as the
  facing page instead of pushing its top row above the screen.
- `enve/Screens/Reader/ReaderScreen.swift` and `ReaderSpreadPolicy`: the facing-page spread, the lectern,
  and the side chrome (close at the top of the column, Contents, Appearance, Search and More at its foot).
  The lectern keeps the engine's view in one place in the tree and only resizes it above the controls
  panel, so folding the phone never rebuilds the navigator or loses the locator; the panel leads with
  Previous page and Next page (labels follow the book's page progression) so the flat half turns pages
  on its own. The reader's chrome takes its Hearth palette from the reader's own colour scheme, so a
  midnight page in a light app keeps legible labels and buttons. The reader keeps the status bar on a
  folding phone: hiding it would collapse the column and reflow the pages on every chrome toggle. The
  spine and the engine's spread request travel together (`ReaderSpreadPolicy.showsSpine`): a book-shaped
  canvas with the automatic or the explicit two-column mode asks both engines for two columns, while an
  explicit single column, scrolling, fixed layout, and accessibility text sizes never spread. ReadiumCSS
  only honours two columns from 60em up, so `ClassicReaderModel` injects a stylesheet lifting the floor
  while the spread is requested, and the Foliate runtime caps a column at half the view so its paginator
  splits the page.

## The facing page

The right page shows whatever is on the mantel. A listening book gets the player, embedded with a
details button in place of the close chevron. An ebook gets the cover, the chapter or page, the ribbon,
and a Continue button, with Listen when a counterpart exists. With nothing on the mantel the page is the
reading room: the flame, an invitation, and a shelf of the newest books, each opening its details on the
facing page. Tapping the pill at the foot of the rail
returns the page to its root; the Hearth tab hides its hero card while that book is on the facing page.

## Trying it without a device

The iPhone Duo simulator in Xcode 27.1 reports the fold and the hinge. Device Hub's pose controls open,
close, rotate, and fold it. Headless runs can force the hinge instead:

```sh
xcrun simctl launch <udid> com.enve.enve -imagineHinge partiallyOpen -imagineScreen player
```

`-imagineHinge closed|partiallyOpen|fullyOpen` fixes the hinge status; the pose then follows the canvas
shape, so a portrait canvas reads as tabletop and a landscape canvas as the book pose. The spread needs
no override on the Duo simulator: it appears whenever the window spans a vertical fold at regular width.
`-imagineFold vertical|horizontal` stands in for the fold on simulators that have none. The nightstand
(dock and full-screen player alike) and the lectern need that horizontal fold as well as the tabletop pose,
so on an ordinary iPhone simulator in portrait pass both `-imagineHinge partiallyOpen` and `-imagineFold
horizontal`; the Duo simulator supplies the fold itself. The Duo simulator's inner display keeps its own
orientation and ignores `XCUIDevice` rotation requests, so the pose tests skip there; Device Hub's controls
are the way to rotate and fold it by hand.

Closed in Device Hub, the simulator lays the app out on the outer display (a 382×644 safe area with the
84pt column on the right and a 170pt status-bar occlusion inside it, hinge status `closed`) but renders
that display black, in Device Hub and in `simctl io screenshot` alike. Verify the pocket through element
frames instead: `axe describe-ui` and the view hierarchies the UI tests record show the rail's tabs in the
column, the stacks stopping at it, and the player's buttons stacked below the status bar.

`DuoLayoutSmokeUITests` (in the `UISmokeTests` plan: `-testPlan UISmokeTests
-only-testing:enveUITests/DuoLayoutSmokeUITests`) drives the shell, player, and reader through both
orientations and both folded poses, records a screenshot and the view hierarchy at each step, and skips
the spread, pocket, and nightstand assertions on devices and poses that don't apply. `DuoShellLayoutTests`, `HingePoseTests`, `PlayerLayoutPolicyTests`, and
`ReaderSpreadPolicyTests` cover the pure layout rules.

## Review verification — 2026-10-20

- Xcode 27.1 builds and launches on Duo / iOS 27.1 and Air / iOS 27.0 succeeded. No new warnings;
  the existing `CloudKitProgressSync` retroactive Sendable warning remains.
- Focused `AllTests` selection: 67 passed across Duo shell, hinge, adaptive grid, player layout,
  reader spread, appearance, companion policy, Foliate runtime and font suites. This was not the full plan.
- `UISmokeTests/DuoLayoutSmokeUITests` on the landscape Duo: five passed, four skipped because the
  required upright or closed pose was absent. Library, facing player, reader chrome and spread passed.
- Air library, player, reader rotation and synthetic-library cleanup: four passed.
- Air with DEBUG hinge and horizontal fold input: lectern, nightstand player and shell dock all passed.
  Screenshots confirm readable midnight-reader controls and reachable lower-panel page turns.
- After separating the bedside clock from the top buttons, the nightstand player test passed again,
  including an assertion that the clock clears the close button.
- `git diff --check` and `scripts/verify-provenance` passed.

## Top-spacing verification — 2026-10-22

- Duo open-layout tests passed for the Hearth header, pushed Settings, facing player, rail, and transport.
  Visual review confirmed the foreground inset and uninterrupted player background.
- The closed-display test passed its control-frame and interaction checks. The simulator still renders
  that display black, so closed-display appearance needs a physical-device visual check.
- Device Hub activated the upright tabletop pose; lectern reader, nightstand player, and shell dock tests passed.
- Air library, player, and reader rotation tests passed. `AllTests` passed 1,625 tests with 33 skips.
- Explicit reader two-column rendering still needs its separate visual qualification.

## Shared-background verification — 2026-10-22

- Visual checks confirmed one continuous glow across Settings, Appearance, the reading room, and the
  embedded player in the open spread. Both Ink and Paper were checked; the original Ink theme was restored.
- Native navigation backgrounds are cleared by each `HearthBackground` as well as the stack roots,
  so pushed destinations do not cover the shared surface.
- Duo player and spread-navigation tests passed. Air appearance persistence, true black, and player
  rotation checks passed. No new compiler warnings; the existing CloudKit Sendable warning remains.

Reader references consulted: Silveran `669a56903316fa51bf9c2850bdc89d9bbcac37dc` and Storyteller
`2f12802e250fba5de8ad3a869feb3c010d39ff3f`, fetched before review.
