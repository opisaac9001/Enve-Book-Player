# E-Ink Mode

E-ink is a first-class display mode on Android, not a theme variant. The app detects EPD hardware, drives vendor refresh APIs where they exist, and degrades every design primitive at the point of use. This has no iOS counterpart.

## Device detection

`EinkDetector` (`:engine`, `com.enve.app.eink`) runs once and produces an `EinkDeviceProfile`:

```kotlin
data class EinkDeviceProfile(
    val isEink: Boolean,
    val vendor: EinkVendor,
    val hasNativeEpdApi: Boolean,
    val hasAudioOutput: Boolean,
    val hasBluetooth: Boolean,
    val screenWidth: Int,
    val screenHeight: Int,
    val refreshRateHz: Float,
    val manufacturer: String,
    val model: String,
)
```

There is no Android API that reports "this is an EPD panel," so detection is layered:

1. `EinkDeviceClassifier.detectVendor` matches the concatenated `Build.MANUFACTURER` / `BRAND` / `DEVICE` / `PRODUCT` / `MODEL` string against a known-vendor allowlist — `EinkVendor` covers BOOX, Hisense, sideloaded Kobo, reMarkable, Bigme, Meebook, PocketBook, InkPalm, NOOK, and a generic EPD bucket.
2. Native EPD APIs are probed: `android.app.EpdController` by reflection for BOOX, and the Hisense EPD package for Hisense.
3. Reported refresh rate in the 0.1–1.5 Hz band is treated as an EPD signal.

A device is inferred to be e-ink if any of those hit. `EinkVendor.needsWebViewSoftwareLayer` records which families need the reader WebView forced onto a software layer, because GPU compositing bands badly under EPD dithering.

## Modes

`EinkDisplayMode` is the user-facing setting, persisted through `PreferencesManager`:

| Mode | Behavior |
|---|---|
| `AUTO` | Follow detection. |
| `ON` ("Mono") | Force optimizations and a monochrome palette. |
| `ON_COLOR` ("Color") | Force optimizations, keep the colour palette — for colour EPD panels. |
| `OFF` | No optimizations, regardless of hardware. |

`EinkManager` owns the resolved state and the persisted knobs (refresh strength, bold text, full-refresh interval). The UI reads it through `EinkFacade`, which exposes `EinkState` — `active`, `monochrome`, `mode`, `boldText`, `refreshStrength` — plus writes and `requestFullRefresh(view)`.

## Refresh policy

EPD panels have two useful refresh classes: a full GC16 flash that clears ghosting but is slow, and a fast partial/A2 update that accumulates ghosting. `EpdRefreshManager` picks between them and issues the vendor call — `EpdController.requestEpdMode` on BOOX, the `com.hisense.eink.action.SET_EPD_MODE` broadcast on Hisense.

Page turns run through `EpdPageTurnPolicy.decide`, which is pure and unit-testable. It takes the user's refresh strength (0–3), the configured full-refresh interval, the number of turns since the last full refresh, and whether the turn crosses a full-page boundary:

| Strength | Behavior |
|---|---|
| 0 | No explicit refresh; leave it to the panel. |
| 1 | Full refresh only at page boundaries. |
| 2 | Partial per turn, full at a boundary or every *N* turns. |
| 3 | Full refresh on every turn. |

Screen transitions go through `requestTransitionRefresh`, which also respects strength. Refreshes are driven by explicit page-turn and navigation actions, never by locator emissions — locators fire far too often and produce visible flashing.

## Design-system degradation

`:hearth-ui` never branches on device model. `HearthEink` wraps `EinkState` and exposes render flags that every primitive reads from `LocalHearth`:

| Flag | Active when | Effect |
|---|---|---|
| `suppressAnimations` | e-ink active | No marquee, ring, or transition animation |
| `suppressShadows` / `borderInsteadOfShadow` | e-ink active | Hairline borders replace elevation |
| `suppressGradients` | e-ink active | Solid fills replace gradients and glow |
| `sharpCorners` | monochrome | Reduced corner radii |
| `marginTapNavigation` | e-ink active | Margin taps turn pages in the reader |
| `singleColumnReader` | e-ink active | Readium is forced to single-column layout |
| `flatTabBar` | e-ink active | Flat MantelBar chrome |
| `denseListLibrary` | e-ink active | Library falls back to a dense single-column list |

When `monochrome` is set, `HearthPalette` flips to its pure black-and-white variant. Because the flags are read at the point of use, a new component gets correct e-ink behavior by consuming Hearth tokens — hard-coded colours are the one thing that breaks it, which is why they are banned in Hearth screens.

## Verifying without hardware

Setting **Settings → E-Ink → On** on a normal phone forces the monochrome palette and every render flag, which catches hard-coded colours, invisible low-contrast chips, and hue-only status encoding. It does not exercise vendor refresh calls or ghosting — those need a real EPD device.
