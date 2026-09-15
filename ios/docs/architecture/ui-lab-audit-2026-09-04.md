# Book Player lab UI audit — September 4, 2026

Status: in progress. Tested on iPhone Air, iOS 26.4.1, using the current main checkout with the existing uncommitted audit changes. Lab addresses and credentials are loaded from ignored CLAUDE.local.md and omitted from this report.

## Plex investigation

The documented Plex endpoint currently reports claimed=true and has enableTrackOffsets=true on its audiobook library. CLAUDE.local.md still describes it as unclaimed and supplies no Plex token. The existing provider harness consequently tests anonymous access. Its focused rerun again sent 23 seconds and read zero; catalog and byte ranges succeeded. This does not establish failure of the authenticated UI connection.

The simulator already contains an authenticated lab Plex source. In Settings → source → Verify, it reports “Connection looks good.” UI playback/persistence investigation continues.

## Service UI matrix

Results will distinguish UI steps actually exercised from provider-only API checks and unsupported lab services.

### Audiobookshelf

Added through Add a source → server detection → username/password. Authentication succeeded and the UI imported 30,186 entries, with visible incremental progress. Source and library filters remained usable; selected Enve Audiobooks and opened Chaptered M4B Book. Chapter selection moved to Middle (0:20); Play advanced the timer, Skip forward moved playback, and Pause stopped near 0:48. An independent authenticated server read returned currentTime=47.878085163, progress=0.79796808605, isFinished=false. Closing/reopening the player resumed near 0:49. This establishes a UI-to-server audio progress write and local resume.

Observed presentation issues: switching away from SSO leaves the old “OIDC requires an HTTPS server URL” message until connecting; 20-second chapters display as “0m” in the player chapter picker; after rewinding a previously completed fixture, the detail page still displayed “Finished” while the server reported isFinished=false. That last mismatch needs a dedicated state-refresh regression; it is not proof of failed server sync.

Audiobookshelf ebook UI: opened the grouped Synthetic EPUB, selected Read, confirmed its actual text rendered (including accented text, Japanese and Arabic), opened Contents and selected Chapter 1. This one-page fixture cannot establish nonzero ebook-position round trips. The grouped ebook copies expose “Play this copy” labels even though the primary action is Read; wording is inconsistent.

### Jellyfin

Server detection and username/password login passed through the UI. In the library chooser, cleared defaults and selected EnveAudiobooks plus EnveBooks, then Done. The source was saved and library import started (30,256 book entries reported for EnveBooks). The selector calls EnveBooks “Audiobooks”; catalog completion, playback and reading checks remain pending.

After import, Back, Add a source and scrolling did not visibly respond to simulator taps even with fresh accessibility references. A two-second process sample showed the main thread largely idle in the run loop rather than CPU-bound/deadlocked; physical footprint was 178 MB, peak 602 MB. Relaunching to determine whether this is app presentation state or automation behavior. Sample: `$TMPDIR/enve-ui-jellyfin-sample.txt`. Do not attribute a main-thread performance freeze from this evidence.

Jellyfin followup after relaunch: Settings shows 30,275 imported items. Relaunch restored navigation; catalog import completed despite the earlier missing count.

### Emby

Server detection, username/password login, fetching the single EnveAudiobooks library, Select All and Done succeeded. The source was saved in Settings. Format/playback checks pending.

Emby followup: Back also stopped responding after Done in its library chooser. Relaunch restored navigation again. This reproduces the post-library-selection input problem across two services; do not attribute it only to large-library import.

## Remaining coverage queue

- Authenticated existing Plex connection: playback, seek, reopen and progress identity comparison.
- Jellyfin, Emby: catalog and available media workflows.
- Komga, Kavita, Grimmory, Storyteller, BookOrbit, Silo: connection and available media workflows.
- WebDAV and Samba: browser/import/download workflows.
- Calibre Content Server, Calibre-Web, Stump: OPDS entry points where supported.
- KOReader/ABS-KOSync and Authentik/mTLS: relevant settings/authentication surfaces; distinguish from independent library sources.
- Navidrome, Gonic, RomM and the Game Master LLM have no corresponding book-player source UI. WireMock and Toxiproxy are test infrastructure, not library providers.

### Komga

Server detection and email/password login passed. The source returned directly to Settings and began importing 30,258 entries in Enve Books. The same post-login navigation failure occurred without a library chooser, widening the problem to the common quick-connect dismissal handoff.

## Presentation correction under verification

SourcesQuickConnectScreen and AddSourceScreen previously removed their presented login sheet and dismissed its presenting screen in the same callback. They now stage successful completion, close the child sheet, and dismiss the parent only from the child's onDismiss callback. Cancellation does not set the success flag. This is a small lifecycle correction; subsequent UI runs must establish whether it resolves the observed input problem. No timed delay or new abstraction was added.

## Latest UI continuation

Kavita: detected and authenticated through the UI; 28 entries imported. Add a source was usable immediately afterwards, without restarting. Cancellation of a detected Grimmory login returned to quick connect. The manual provider picker opened, Grimmory's form opened, and Cancel returned to the picker. Manual sign-in completion remains unverified: the nested screen's runtime accessibility capture omitted necessary keyboard controls.

Grimmory: automatic detection and username/password login succeeded. Back returned from Settings to Hearth and the library remained navigable without relaunch. The initial Settings count was still pending; catalog completion and content workflows remain unverified. An Add a source tap did not navigate with eight sources present, but Back worked; this particular tap may target a control outside the visible viewport and does not establish another presentation failure.

Kavita content: source filtering showed 28 books. Opened Enve Synthetic Comic, selected Read, visually confirmed the red first fixture page and swiped to the green second page. The detail state then reported COMIC, CBZ, Downloaded, 50% read and Saved to the server. This confirms rendering, page navigation and the application's reported sync completion; an independent server read and relaunch/resume are still required.

The two-file dismissal correction built with zero errors and warnings (build_run_sim_2026-09-05T04-32-35-881Z_pid13810_3759a9d9.log). Subsequent Kavita and Grimmory connections allowed navigation without restarting. This is useful runtime evidence, but the library-chooser and successful manual-login paths still need regression coverage.

### Current environment blocker

Native UI control reported: “The Mac is locked and automatic unlock could not unlock it.” It explicitly requires a manual unlock. The simulator runtime tools can still perform some semantic actions, but text injection does not enter characters and the comic's hidden controls are not exposed as tappable elements. The full UI run is paused for manual unlock; this report is not a full-service pass. Remaining items above are still pending.

## Resumed after manual unlock

The typing command works after unlock. A separate task was also using the original iPhone Air. After coordinating a pause, cloned it to Enve Book UI Audit iPhone Air (same iPhone Air hardware/runtime and app state); original was rebooted and released to the other task. Remaining work uses the isolated clone. Browser mirroring provides actual reader controls when semantic references have disappeared.

Kavita resumed on Page 2 of 3 after relaunch. Hearth displayed 33% while the reader displayed 50%, exposing inconsistent page-progress denominators. Reached the blue third fixture page and closed the reader through its visible close control.

Plex multi-track playback reproduced a real HTTP404 failure. Inspection found stored track URLs recursively prefixed with the server address, whereas fresh server metadata provided valid relative part keys. startPlaybackSession previously appended cached contentUrl to the base URL on every session, including when contentUrl was already absolute. The correction fetches current track metadata in batches, resolves part keys by track ID, and preserves stored grouping/order/offsets. It rejects missing tracks/parts and unsuccessful metadata responses instead of returning a shortened timeline. Regression tests cover damaged URLs, reversed metadata order, cross-album tracks, replay from saved absolute URLs, missing parts and server errors. Build/test and fixed UI playback verification remain in progress.

Storyteller: automatic detection selected web login and displayed the system sign-in consent. Cancel returned to its form. Switched to username/password and connected using the documented local administrator; eight items imported. Web login completion and content workflows remain pending.

Silo: detection and username/password login succeeded; library chooser offered Enve Test Books. Select All and Done returned to Settings. This exercises a library-chooser success with the staged dismissal change. Content workflows remain pending.
