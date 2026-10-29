# Liseur reader behavior

Source: https://github.com/chmouel/liseur

Reviewed revision: `1822c64b6a462e6d9285a1b43e2ec7448e4a7719` (2026-10-29).

The EPUB wide-content fitting scripts adapt `reader/WideContentFit.kt`: measure individual column fragments, constrain only overflowing tables and preformatted blocks, and retain publisher styling elsewhere. The held-location, reading-pace, illustration-viewer and pinch-resize behavior informed Enve-specific implementations. Liseur is not a runtime dependency. Its MIT license is retained in `LICENSE.txt` and the application bundle.
