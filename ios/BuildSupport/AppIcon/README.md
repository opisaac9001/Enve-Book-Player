# Book Player icons

`enve-book-player-icon.svg` is the square iPhone/iPad icon master.

`enve-book-player-tv.svg` adapts that artwork for Apple TV with separate `background`, `book`, and `ember` groups. The book and shelf sit behind the central ember for tvOS parallax. Keep the groups in the same coordinate system.

Regenerate the Apple TV assets from the repository root:

```sh
scripts/generate-tv-top-shelf
```

Requires Python 3 and `rsvg-convert` from librsvg. Top Shelf text uses Georgia and Helvetica on macOS.

The generator centers the transparent artwork in the landscape icon at 400×240, 800×480, and 1280×768, with a full-width opaque brown back layer. It also generates standard and wide Top Shelf artwork at 1× and 2×, following the Video Player's layout. iOS assets are unchanged.
