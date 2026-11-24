# Page-turn animation

The reader's Appearance sheet offers Standard and Curl in paged mode for ebooks and PDFs. Standard remains the default. The choice is part of the existing per-profile `ClassicReaderAppearance` persistence; older settings decode to Standard.

Curl applies to command-driven page turns: edge taps, page controls, keyboard, game controller and volume-button navigation. PDF swipe turns use the same command path. EPUB and Foliate's interactive swipe gestures retain their engine animation. Comics and HTML retain their current presentation. This is a vertical UIKit curl, not a finger-tracked horizontal page curl. Scrolled mode and Reduce Motion bypass it without clearing the saved choice.

`ReaderPageTurnAnimator` briefly overlays snapshots around an existing engine navigation operation. The live renderer remains mounted and keeps ownership of text selection, locators, statistics and progress. Successful turns curl up going forward and down going backward. Failed or cancelled moves, detached views and changed view sizes discard the overlay. A second page command is ignored while the first curl is pending. Snapshots are removed after each operation; they are not a book-sized image cache.

API references checked: Apple's [view snapshots](https://developer.apple.com/documentation/uikit/uiview/snapshotview(afterscreenupdates:)), [view transitions](https://developer.apple.com/documentation/uikit/uiview/transition(from:to:duration:options:completion:)) and [curl-up transition](https://developer.apple.com/documentation/uikit/uiview/animationoptions/transitioncurlup). The pinned Readium 3.11 EPUB navigator supports an animated navigation flag but no public curl setting.
