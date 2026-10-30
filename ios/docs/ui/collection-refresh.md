# Book collection visual refresh

The Book Player keeps its existing icon and Hearth navigation. Its interface
now shares the Enve family’s illustrated collection styling: brown and cream,
ink outlines, wood ledges, and book bindings behind cover art.

## Shared components

- `HearthPalette` supplies Ink `#2D2322`, elevated `#3A2B26`, cream `#F6DEAA`,
  wood `#794B31`, and ink `#1C1513`. Paper accents retain a 5.6:1 contrast target
  against the new cream canvas. OLED keeps its true-black surfaces.
- Classic chrome uses 1.5pt outlines and a 3pt wood base for raised surfaces.
  Explicit accent strokes, high contrast, Reduce Transparency, custom accents,
  and the optional Liquid Glass style remain supported.
- `CoverTile` draws binding and page edges behind the original artwork without
  changing its aspect ratio, crop, progress, or format badges.
- Hearth shelves align mixed cover formats to one ledge. Continue cards,
  settings badges, and the dock use the same illustrated linework.
- The bottom Mantel bar is 76pt on iPhone and 88pt on iPad, with 24pt tab
  symbols and 13pt labels. Compact tab targets are 52×56pt. Liquid Glass uses
  an 84pt bar. Content insets follow the bar’s measured height; the adaptive
  accessibility layout and Duo rail placement remain intact.

This refresh changes presentation only. The existing in-progress work in other
files is independent of this patch. All app-icon assets remain unchanged.

## Verification — 2026-10-25

- Built and launched the `enve` scheme on iPhone Air and iPad Pro 13-inch (M4),
  both on iOS 27 Simulator. No build errors; no warnings in the changed UI files.
- `AllTests`, restricted to `CoverTileTests` and `HearthAdaptiveLayoutTests`:
  9 tests passed (26 parameterized cases), zero failures or skips.
- `UISmokeTests`, restricted to `AppearanceSettingsUITests`: passed. Verified
  live theme changes, true-black OLED, and persistence across relaunch.
- Manually exercised Hearth, Library cover stacks, and settings in Paper,
  Ink, OLED, and the largest accessibility text size. Scrolled settings to
  Advanced and About; their actions remained reachable. Opened a local EPUB
  and verified the reader chrome and Appearance sheet without changing its theme.
- All 16 existing app-icon asset files match their pre-change SHA-256 hashes.
  No icon sources or assets were edited.

Commands used the existing cache at
the project’s external DerivedData directory. Test result bundles:
`/private/tmp/enve-book-collection-unit.xcresult` and
`/private/tmp/enve-book-collection-appearance.xcresult`.

The recompile exposes an existing warning in `Services/Sync/CloudKitSink.swift:55`
about retroactive `Sendable` conformance for `CloudKitProgressSync`. That source
was not changed. `scripts/verify-provenance` remains blocked by a machine-specific
path in the pre-existing dirty `docs/testing/kokoro-on-device.md`; this UI pass
preserves that work. Physical-device, tvOS, playback-engine, provider, and
reader-engine regression testing are outside this presentation-only pass.

## Bottom navigation sizing follow-up

Enlarged the classic and Liquid Glass bottom bars after feedback that the
navigation was too small. Built and exercised tab navigation on iPhone Air
and iPad Pro 13-inch (M4). The final iPad build passed without warnings; the
iPhone recompile emitted only the existing sync conformance warning above.
